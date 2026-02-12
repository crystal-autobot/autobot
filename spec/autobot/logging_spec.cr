require "../spec_helper"

describe Autobot::Logging do
  describe ".setup" do
    after_each do
      ::Log.setup(::Log::Severity::None)
    end

    it "sets up console-only logging" do
      Autobot::Logging.setup(log_level: Autobot::Logging::Level::Info)
      # Should not raise
    end

    it "sets up file + console logging" do
      tmp = TestHelper.tmp_dir
      Autobot::Logging.setup(
        log_level: Autobot::Logging::Level::Debug,
        log_dir: tmp.to_s
      )

      File.exists?(tmp / "autobot.log").should be_true
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "TokenTracker" do
    it "starts with zero tokens" do
      tracker = Autobot::Logging::TokenTracker.new
      tracker.total_prompt_tokens.should eq(0)
      tracker.total_completion_tokens.should eq(0)
      tracker.total_tokens.should eq(0)
      tracker.total_requests.should eq(0)
    end

    it "records token usage" do
      tracker = Autobot::Logging::TokenTracker.new
      tracker.record(prompt_tokens: 100, completion_tokens: 50, model: "claude-3")

      tracker.total_prompt_tokens.should eq(100)
      tracker.total_completion_tokens.should eq(50)
      tracker.total_tokens.should eq(150)
      tracker.total_requests.should eq(1)
    end

    it "accumulates across multiple requests" do
      tracker = Autobot::Logging::TokenTracker.new
      tracker.record(prompt_tokens: 100, completion_tokens: 50)
      tracker.record(prompt_tokens: 200, completion_tokens: 100)

      tracker.total_prompt_tokens.should eq(300)
      tracker.total_completion_tokens.should eq(150)
      tracker.total_tokens.should eq(450)
      tracker.total_requests.should eq(2)
    end

    it "generates summary" do
      tracker = Autobot::Logging::TokenTracker.new
      tracker.record(prompt_tokens: 100, completion_tokens: 50)
      summary = tracker.summary
      summary.should contain("1 requests")
      summary.should contain("150 total tokens")
    end

    it "resets counters" do
      tracker = Autobot::Logging::TokenTracker.new
      tracker.record(prompt_tokens: 100, completion_tokens: 50)
      tracker.reset
      tracker.total_tokens.should eq(0)
      tracker.total_requests.should eq(0)
    end
  end

  describe "FileTracker" do
    it "starts empty" do
      tracker = Autobot::Logging::FileTracker.new
      tracker.touched_files.should be_empty
    end

    it "records file operations" do
      tracker = Autobot::Logging::FileTracker.new
      tracker.record("read", "/tmp/file.txt")
      tracker.record("write", "/tmp/output.txt", bytes: 1024)

      tracker.touched_files.size.should eq(2)
      tracker.touched_files.should contain("/tmp/file.txt")
      tracker.touched_files.should contain("/tmp/output.txt")
    end

    it "deduplicates touched files" do
      tracker = Autobot::Logging::FileTracker.new
      tracker.record("read", "/tmp/file.txt")
      tracker.record("write", "/tmp/file.txt", bytes: 100)

      tracker.touched_files.size.should eq(1)
    end

    it "generates summary" do
      tracker = Autobot::Logging::FileTracker.new
      tracker.record("read", "/tmp/a.txt")
      tracker.record("write", "/tmp/b.txt")
      tracker.record("read", "/tmp/c.txt")

      summary = tracker.summary
      summary.should contain("3 file ops")
      summary.should contain("read=2")
      summary.should contain("write=1")
    end

    it "resets operations" do
      tracker = Autobot::Logging::FileTracker.new
      tracker.record("read", "/tmp/a.txt")
      tracker.reset
      tracker.touched_files.should be_empty
    end
  end
end
