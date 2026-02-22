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
end
