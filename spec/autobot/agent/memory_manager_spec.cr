require "../../spec_helper"

# Mock provider for memory manager tests.
class MemoryMockProvider < Autobot::Providers::HttpProvider
  getter call_count : Int32 = 0

  def initialize
    super(api_key: "test-key", model: "mock-model")
  end

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    @call_count += 1
    json_response = %({"history_entry":"[2025-01-01] Summary of conversation","memory_update":"User prefers dark mode"})
    HTTP::Client::Response.new(200, body: %({"choices":[{"message":{"content":#{json_response.to_json}},"finish_reason":"stop"}],"usage":{"prompt_tokens":50,"completion_tokens":20,"total_tokens":70}}))
  end
end

describe Autobot::Agent::MemoryManager do
  describe "constants" do
    it "has proper constant values for memory management" do
      Autobot::Agent::MemoryManager::DISABLED_MEMORY_WINDOW.should eq(0)
      Autobot::Agent::MemoryManager::MAX_MESSAGES_WITHOUT_CONSOLIDATION.should eq(10)
      Autobot::Agent::MemoryManager::MIN_KEEP_COUNT.should eq(2)
      Autobot::Agent::MemoryManager::MAX_KEEP_COUNT.should eq(10)
    end
  end

  describe "#enabled?" do
    it "returns false when memory_window is 0" do
      tmp = TestHelper.tmp_dir
      provider = MemoryMockProvider.new
      sessions = Autobot::Session::Manager.new(tmp)

      manager = Autobot::Agent::MemoryManager.new(
        workspace: tmp,
        provider: provider,
        model: "mock-model",
        memory_window: 0,
        sessions: sessions
      )

      manager.enabled?.should be_false
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns true when memory_window is positive" do
      tmp = TestHelper.tmp_dir
      provider = MemoryMockProvider.new
      sessions = Autobot::Session::Manager.new(tmp)

      manager = Autobot::Agent::MemoryManager.new(
        workspace: tmp,
        provider: provider,
        model: "mock-model",
        memory_window: 10,
        sessions: sessions
      )

      manager.enabled?.should be_true
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "#trim_if_disabled" do
    it "trims messages when disabled and over limit" do
      tmp = TestHelper.tmp_dir
      provider = MemoryMockProvider.new
      sessions = Autobot::Session::Manager.new(tmp)

      manager = Autobot::Agent::MemoryManager.new(
        workspace: tmp,
        provider: provider,
        model: "mock-model",
        memory_window: 0,
        sessions: sessions
      )

      session = sessions.get_or_create("test:trim")
      15.times { |i| session.add_message("user", "Message #{i}") }
      session.messages.size.should eq(15)

      manager.trim_if_disabled(session)

      session.messages.size.should eq(10)
      session.messages.first.content.should eq("Message 5")
      session.messages.last.content.should eq("Message 14")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "does not trim when under limit" do
      tmp = TestHelper.tmp_dir
      provider = MemoryMockProvider.new
      sessions = Autobot::Session::Manager.new(tmp)

      manager = Autobot::Agent::MemoryManager.new(
        workspace: tmp,
        provider: provider,
        model: "mock-model",
        memory_window: 0,
        sessions: sessions
      )

      session = sessions.get_or_create("test:no_trim")
      5.times { |i| session.add_message("user", "Message #{i}") }

      manager.trim_if_disabled(session)

      session.messages.size.should eq(5)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "#consolidate_if_needed" do
    it "trims session synchronously before background summarization" do
      tmp = TestHelper.tmp_dir
      Dir.mkdir_p(tmp / "memory")
      provider = MemoryMockProvider.new
      sessions = Autobot::Session::Manager.new(tmp)

      manager = Autobot::Agent::MemoryManager.new(
        workspace: tmp,
        provider: provider,
        model: "mock-model",
        memory_window: 6,
        sessions: sessions
      )

      session = sessions.get_or_create("test:consolidate")
      10.times { |i| session.add_message("user", "Message #{i}") }
      session.messages.size.should eq(10)

      manager.consolidate_if_needed(session)

      # Session should be trimmed immediately (synchronously)
      # keep_count = min(10, max(2, 6 // 2)) = 3
      session.messages.size.should eq(3)
      session.messages.last.content.should eq("Message 9")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "does not trim when under memory_window threshold" do
      tmp = TestHelper.tmp_dir
      provider = MemoryMockProvider.new
      sessions = Autobot::Session::Manager.new(tmp)

      manager = Autobot::Agent::MemoryManager.new(
        workspace: tmp,
        provider: provider,
        model: "mock-model",
        memory_window: 20,
        sessions: sessions
      )

      session = sessions.get_or_create("test:under_threshold")
      5.times { |i| session.add_message("user", "Message #{i}") }

      manager.consolidate_if_needed(session)

      session.messages.size.should eq(5)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "allows safe concurrent session writes after consolidation" do
      tmp = TestHelper.tmp_dir
      Dir.mkdir_p(tmp / "memory")
      provider = MemoryMockProvider.new
      sessions = Autobot::Session::Manager.new(tmp)

      manager = Autobot::Agent::MemoryManager.new(
        workspace: tmp,
        provider: provider,
        model: "mock-model",
        memory_window: 6,
        sessions: sessions
      )

      session = sessions.get_or_create("test:concurrent")
      10.times { |i| session.add_message("user", "Message #{i}") }

      manager.consolidate_if_needed(session)

      # After synchronous trim, adding new messages is safe
      session.add_message("user", "New message after consolidation")
      sessions.save(session)

      # Give background fiber time to complete
      sleep(100.milliseconds)

      # Reload from disk to verify no corruption
      reloaded = sessions.get_or_create("test:concurrent")

      # Should have the trimmed messages plus the new one
      reloaded.messages.size.should eq(4) # 3 kept + 1 new
      reloaded.messages.last.content.should eq("New message after consolidation")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "writes memory files in background after consolidation" do
      tmp = TestHelper.tmp_dir
      Dir.mkdir_p(tmp / "memory")
      provider = MemoryMockProvider.new
      sessions = Autobot::Session::Manager.new(tmp)

      manager = Autobot::Agent::MemoryManager.new(
        workspace: tmp,
        provider: provider,
        model: "mock-model",
        memory_window: 6,
        sessions: sessions
      )

      session = sessions.get_or_create("test:memory_files")
      10.times { |i| session.add_message("user", "Message #{i}") }

      manager.consolidate_if_needed(session)

      # Give background fiber time to complete
      sleep(200.milliseconds)

      provider.call_count.should be > 0

      # Check that memory files were updated
      memory_file = tmp / "memory" / "MEMORY.md"
      history_file = tmp / "memory" / "HISTORY.md"

      if File.exists?(memory_file)
        File.read(memory_file).should contain("dark mode")
      end

      if File.exists?(history_file)
        File.read(history_file).should contain("Summary of conversation")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end
end
