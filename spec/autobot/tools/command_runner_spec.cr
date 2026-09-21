require "../../spec_helper"

describe Autobot::Tools::CommandRunner do
  describe ".run" do
    it "captures stdout and stderr of a successful command" do
      result = Autobot::Tools::CommandRunner.run("sh", ["-c", "echo out; echo err >&2"], 5)

      result.success?.should be_true
      result.timed_out?.should be_false
      result.exit_code.should eq(0)
      result.stdout.should eq("out\n")
      result.stderr.should eq("err\n")
    end

    it "reports the exit code of a failed command" do
      result = Autobot::Tools::CommandRunner.run("sh", ["-c", "exit 3"], 5)

      result.success?.should be_false
      result.timed_out?.should be_false
      result.exit_code.should eq(3)
    end

    it "does not mistake a real exit code 124 for a timeout" do
      result = Autobot::Tools::CommandRunner.run("sh", ["-c", "exit 124"], 5)

      result.timed_out?.should be_false
      result.exit_code.should eq(124)
    end

    it "has no exit code when the command is killed by a signal" do
      result = Autobot::Tools::CommandRunner.run("sh", ["-c", "kill -KILL $$"], 5)

      result.success?.should be_false
      result.timed_out?.should be_false
      result.exit_code.should be_nil
    end

    it "marks a command that outlives the timeout as timed out and keeps its output" do
      result = Autobot::Tools::CommandRunner.run("sh", ["-c", "echo working; exec sleep 5"], 1)

      result.timed_out?.should be_true
      result.success?.should be_false
      result.status.should be_nil
      result.exit_code.should be_nil
      result.stdout.should eq("working\n")
    end

    it "stops waiting as soon as the command obeys the termination signal" do
      start = Time.instant
      Autobot::Tools::CommandRunner.run("sleep", ["5"], 1)
      elapsed = Time.instant - start

      (elapsed < 1.second + Autobot::Tools::CommandRunner::SIGNAL_GRACE_PERIOD).should be_true
    end

    it "kills a command that ignores the termination signal" do
      result = Autobot::Tools::CommandRunner.run("sh", ["-c", "trap '' TERM; sleep 5"], 1)

      result.timed_out?.should be_true
    end

    it "truncates output above the size limit" do
      result = Autobot::Tools::CommandRunner.run("sh", ["-c", "printf 'abcdefghij'"], 5, max_output_size: 4)

      result.stdout.should eq("abcd\n... (output truncated at 4 bytes)")
    end

    it "runs the command in the given directory" do
      dir = File.realpath(Dir.tempdir)

      result = Autobot::Tools::CommandRunner.run("pwd", [] of String, 5, chdir: dir)

      result.stdout.strip.should eq(dir)
    end
  end
end
