require "../../spec_helper"

describe Autobot::Tools::SandboxExecutor do
  describe "#exec direct execution" do
    it "returns the captured output for a simple command" do
      # Arrange
      executor = Autobot::Tools::SandboxExecutor.new(nil)

      # Act
      result = executor.exec("echo hello")

      # Assert
      result.success?.should be_true
      result.content.strip.should eq("hello")
    end

    it "does not hang when a command leaves a daemon holding the pipe open" do
      # Arrange — the daemon keeps the stdout write end open after `sh` exits.
      # Without closing the read ends, the reader fibers block until the daemon
      # exits (~3s here), so the elapsed time catches the regression.
      executor = Autobot::Tools::SandboxExecutor.new(nil)

      # Act
      start = Time.instant
      result = executor.exec("echo started; sleep 3 &")
      elapsed = Time.instant - start

      # Assert
      result.success?.should be_true
      result.content.strip.should start_with("started")
      (elapsed < 1.second).should be_true
    end
  end
end
