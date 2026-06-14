require "../../spec_helper"

describe Autobot::Tools::SandboxExecutor do
  describe "#exec direct execution" do
    it "returns the captured output for a simple command" do
      executor = Autobot::Tools::SandboxExecutor.new(nil)

      result = executor.exec("echo hello")

      result.success?.should be_true
      result.content.strip.should eq("hello")
    end

    it "does not hang when a command leaves a daemon holding the pipe open" do
      executor = Autobot::Tools::SandboxExecutor.new(nil)

      # The daemon holds the pipe open after `sh` exits; without the fix the
      # reader fibers block until it dies (~3s), so timing catches the regression.
      start = Time.instant
      result = executor.exec("echo started; sleep 3 &")
      elapsed = Time.instant - start

      result.success?.should be_true
      result.content.strip.should start_with("started")
      (elapsed < 1.second).should be_true
    end
  end
end
