require "../../spec_helper"

private def run(script : String, timeout : Int32 = 5) : Autobot::Tools::CommandRunner::Result
  Autobot::Tools::CommandRunner.run("sh", ["-c", script], timeout)
end

describe Autobot::Tools::CommandRunner do
  describe ".run" do
    it "captures stdout and stderr of a successful command" do
      result = run("echo out; echo err >&2")

      result.success?.should be_true
      result.timed_out?.should be_false
      result.stdout.should eq("out\n")
      result.stderr.should eq("err\n")
    end

    it "treats exit code 124 as a plain failure, not a timeout" do
      result = run("exit 124")

      result.success?.should be_false
      result.timed_out?.should be_false
      result.status.try(&.exit_code).should eq(124)
    end

    it "marks a command that outlives the timeout as timed out, keeps its output and stops on SIGTERM" do
      start = Time.instant
      result = run("echo working; exec sleep 5", timeout: 1)
      elapsed = Time.instant - start

      result.timed_out?.should be_true
      result.success?.should be_false
      result.stdout.should eq("working\n")
      (elapsed < 1.second + Autobot::Tools::CommandRunner::SIGNAL_GRACE_PERIOD).should be_true
    end

    it "kills a command that ignores the termination signal" do
      run("trap '' TERM; sleep 5", timeout: 1).timed_out?.should be_true
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

    it "forwards environment variables" do
      result = Autobot::Tools::CommandRunner.run(
        "sh",
        ["-c", "echo $TEST_VAR"],
        5,
        env: {"TEST_VAR" => "runner_val"}
      )

      result.success?.should be_true
      result.stdout.strip.should eq("runner_val")
    end

    it "keeps truncated output valid utf-8 when the cut splits a character" do
      result = Autobot::Tools::CommandRunner.run(
        "sh",
        ["-c", "yes € | head -n 100 | tr -d '\\n'"],
        5,
        max_output_size: 10
      )

      result.stdout.valid_encoding?.should be_true
      result.stdout.should contain("output truncated at 10 bytes")
    end

    it "closes pipes when the process cannot be started" do
      attempts = 10
      open_fds = Dir.children("/dev/fd").size

      attempts.times do
        expect_raises(File::NotFoundError) do
          Autobot::Tools::CommandRunner.run("autobot-missing-binary", [] of String, 5)
        end
      end

      # the stdlib leaves one stray fd per failed exec until GC runs; a leaked pipe pair adds four
      leaked = Dir.children("/dev/fd").size - open_fds
      leaked.should be < attempts * 2
    end
  end

  describe "Result#report" do
    it "joins stdout, stderr and the exit code of a failed command" do
      run("echo out; echo err >&2; exit 3").report.should eq("out\n\nSTDERR:\nerr\n\n\nExit code: 3")
    end

    it "is empty when a successful command prints nothing" do
      run("true").report.should be_empty
    end

    it "leaves out a blank stderr" do
      run("echo out; echo >&2").report.should eq("out\n")
    end

    it "names the signal that killed the command" do
      run("kill -KILL $$").report.should eq("\nKilled by signal KILL")
    end

    it "starts with the timeout and has no exit code when the command timed out" do
      result = Autobot::Tools::CommandRunner::Result.new(nil, "working\n", "", 7)

      result.report.should eq("Error: Command timed out after 7 seconds\nworking\n")
    end
  end
end
