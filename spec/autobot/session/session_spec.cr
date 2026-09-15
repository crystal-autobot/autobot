require "../../spec_helper"

describe Autobot::Session::Session do
  it "creates a new empty session" do
    session = Autobot::Session::Session.new(key: "telegram:123")
    session.key.should eq("telegram:123")
    session.messages.should be_empty
  end

  it "adds a message" do
    session = Autobot::Session::Session.new(key: "test:1")
    session.add_message("user", "Hello!")

    session.messages.size.should eq(1)
    session.messages[0].role.should eq("user")
    session.messages[0].content.should eq("Hello!")
  end

  it "updates timestamp on message add" do
    session = Autobot::Session::Session.new(key: "test:1")
    before = session.updated_at
    sleep 10.milliseconds
    session.add_message("user", "Hello!")
    session.updated_at.should be > before
  end

  it "tracks tools used in messages" do
    session = Autobot::Session::Session.new(key: "test:1")
    session.add_message("assistant", "Using tools", tools_used: ["read_file", "exec"])

    session.messages[0].tools_used.should eq(["read_file", "exec"])
  end

  describe "#get_history" do
    it "returns all messages when under limit" do
      session = Autobot::Session::Session.new(key: "test:1")
      session.add_message("user", "msg1")
      session.add_message("assistant", "msg2")

      history = session.get_history
      history.size.should eq(2)
      history[0]["role"].should eq("user")
      history[0]["content"].should eq("msg1")
    end

    it "truncates to max_messages" do
      session = Autobot::Session::Session.new(key: "test:1")
      60.times { |i| session.add_message("user", "msg#{i}") }

      history = session.get_history(max_messages: 10)
      history.size.should eq(10)
      # Should be the last 10 messages
      history[0]["content"].should eq("msg50")
      history[9]["content"].should eq("msg59")
    end

    it "uses default max history of 25" do
      Autobot::Session::Session::DEFAULT_MAX_HISTORY.should eq(25)

      session = Autobot::Session::Session.new(key: "test:1")
      40.times { |i| session.add_message("user", "msg#{i}") }

      history = session.get_history
      history.size.should eq(25)
      history[0]["content"].should eq("msg15")
    end
  end

  describe "#clear" do
    it "clears all messages" do
      session = Autobot::Session::Session.new(key: "test:1")
      session.add_message("user", "Hello!")
      session.add_message("assistant", "Hi!")

      session.clear
      session.messages.should be_empty
    end
  end
end

describe Autobot::Session::Message do
  it "serializes to JSON" do
    msg = Autobot::Session::Message.new(role: "user", content: "hello")
    json = msg.to_json
    parsed = JSON.parse(json)
    parsed["role"].as_s.should eq("user")
    parsed["content"].as_s.should eq("hello")
    parsed["timestamp"].as_s.should_not be_empty
  end

  it "deserializes from JSON" do
    json = %({"role":"assistant","content":"hi","timestamp":"2025-01-01T00:00:00Z"})
    msg = Autobot::Session::Message.from_json(json)
    msg.role.should eq("assistant")
    msg.content.should eq("hi")
  end
end

describe Autobot::Session::Metadata do
  it "serializes to JSON with key" do
    meta = Autobot::Session::Metadata.new(
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      key: "telegram:user_123"
    )
    json = meta.to_json
    parsed = JSON.parse(json)
    parsed["_type"].as_s.should eq("metadata")
    parsed["key"].as_s.should eq("telegram:user_123")
  end

  it "deserializes from JSON with null or missing key" do
    json = %({"_type":"metadata","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","key":null})
    meta = Autobot::Session::Metadata.from_json(json)
    meta.key.should be_nil
  end
end

describe Autobot::Session::Manager do
  it "creates a new session" do
    tmp = TestHelper.tmp_dir
    manager = Autobot::Session::Manager.new(workspace: tmp)
    session = manager.get_or_create("test:123")
    session.key.should eq("test:123")
    session.messages.should be_empty
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns the same session on repeat access" do
    tmp = TestHelper.tmp_dir
    manager = Autobot::Session::Manager.new(workspace: tmp)
    s1 = manager.get_or_create("test:123")
    s1.add_message("user", "hello")
    s2 = manager.get_or_create("test:123")
    s2.messages.size.should eq(1)
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "saves and loads a session" do
    tmp = TestHelper.tmp_dir
    unique_key = "persist:test_#{Random.new.hex(8)}"
    manager = Autobot::Session::Manager.new(workspace: tmp)

    session = manager.get_or_create(unique_key)
    session.add_message("user", "test message")
    session.add_message("assistant", "response")
    manager.save(session)

    # Create new manager to force load from disk
    manager2 = Autobot::Session::Manager.new(workspace: tmp)
    loaded = manager2.get_or_create(unique_key)
    loaded.key.should eq(unique_key)
    loaded.messages.size.should eq(2)
    loaded.messages[0].content.should eq("test message")
    loaded.messages[1].content.should eq("response")
  ensure
    FileUtils.rm_rf(tmp) if tmp
    # Clean up from global sessions dir since Manager uses ~/.autobot/sessions/
    if unique_key
      safe = unique_key.gsub(":", "_").gsub(/[^\w\-.]/, "_")
      global_path = Path.home / ".autobot" / "sessions" / "#{safe}.jsonl"
      File.delete(global_path) if File.exists?(global_path)
    end
  end

  it "deletes a session" do
    tmp = TestHelper.tmp_dir
    manager = Autobot::Session::Manager.new(workspace: tmp)

    session = manager.get_or_create("delete:me")
    session.add_message("user", "temp")
    manager.save(session)

    manager.delete("delete:me").should be_true
    manager.delete("delete:me").should be_false # Already deleted
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  describe "#list_sessions" do
    it "preserves canonical session keys with underscores" do
      tmp = TestHelper.tmp_dir
      manager = Autobot::Session::Manager.new(workspace: tmp)

      session = manager.get_or_create("telegram:user_12345")
      session.add_message("user", "hello")
      manager.save(session)

      sessions = manager.list_sessions
      sessions.size.should eq(1)
      sessions.first["key"].should eq("telegram:user_12345")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "falls back to filename substitution for legacy session files without key in metadata" do
      tmp = TestHelper.tmp_dir
      manager = Autobot::Session::Manager.new(workspace: tmp)

      # Create a legacy session file without "key" in the metadata header
      sessions_dir = tmp / "sessions"
      Dir.mkdir_p(sessions_dir)
      legacy_path = sessions_dir / "legacy_session_1.jsonl"
      File.write(legacy_path, <<-JSON
        {"_type":"metadata","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","metadata":{}}
        {"role":"user","content":"legacy message","timestamp":"2026-01-01T00:00:00Z"}
        JSON
      )

      sessions = manager.list_sessions
      sessions.size.should eq(1)
      sessions.first["key"].should eq("legacy:session:1")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "handles null or empty key in metadata without raising TypeCastError" do
      tmp = TestHelper.tmp_dir
      manager = Autobot::Session::Manager.new(workspace: tmp)

      sessions_dir = tmp / "sessions"
      Dir.mkdir_p(sessions_dir)
      null_key_path = sessions_dir / "session_with_null_key.jsonl"
      File.write(null_key_path, <<-JSON
        {"_type":"metadata","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","key":null,"metadata":{}}
        {"role":"user","content":"test","timestamp":"2026-01-01T00:00:00Z"}
        JSON
      )

      empty_key_path = sessions_dir / "session_with_empty_key.jsonl"
      File.write(empty_key_path, <<-JSON
        {"_type":"metadata","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","key":"","metadata":{}}
        {"role":"user","content":"test","timestamp":"2026-01-01T00:00:00Z"}
        JSON
      )

      sessions = manager.list_sessions
      sessions.size.should eq(2)
      keys = sessions.map { |entry| entry["key"] }
      keys.should contain("session:with:null:key")
      keys.should contain("session:with:empty:key")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "#get_or_create cache synchronization" do
    it "synchronizes cache when loaded session canonical key differs from query key" do
      tmp = TestHelper.tmp_dir
      manager = Autobot::Session::Manager.new(workspace: tmp)

      # Save a session whose canonical key is telegram:user_123
      session = manager.get_or_create("telegram:user_123")
      session.add_message("user", "test")
      manager.save(session)

      # In a fresh manager instance, load via colon key which maps to telegram_user_123.jsonl
      manager2 = Autobot::Session::Manager.new(workspace: tmp)
      loaded = manager2.get_or_create("telegram:user:123")
      loaded.key.should eq("telegram:user_123")

      # Both keys should return the exact same in-memory session reference
      manager2.get_or_create("telegram:user_123").should be(loaded)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end
end
