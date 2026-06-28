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

  it "bypasses sandbox for filesystem operations when sandboxed is false" do
    tmp = TestHelper.tmp_dir
    file = tmp / "test.txt"
    File.write(file, "hello sandbox none")

    # Initialize with sandboxed: false
    executor = Autobot::Tools::SandboxExecutor.new(tmp, sandboxed: false)
    executor.sandboxed?.should be_false

    # read_file should read directly
    result = executor.read_file(file.to_s)
    result.success?.should be_true
    result.content.should eq("hello sandbox none")

    # write_file should write directly
    write_result = executor.write_file((tmp / "written.txt").to_s, "direct write")
    write_result.success?.should be_true
    File.read(tmp / "written.txt").should eq("direct write")

    # list_dir should list directly
    list_result = executor.list_dir(tmp.to_s)
    list_result.success?.should be_true
    list_result.content.should contain("test.txt")
    list_result.content.should contain("written.txt")

    # exec should execute directly
    exec_result = executor.exec("echo hello direct")
    exec_result.success?.should be_true
    exec_result.content.strip.should eq("hello direct")

    # exec_program should execute directly too
    program_result = executor.exec_program("echo", ["hello", "program"])
    program_result.success?.should be_true
    program_result.content.strip.should eq("hello program")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
