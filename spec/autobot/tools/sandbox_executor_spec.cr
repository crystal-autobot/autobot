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

  it "bypasses sandbox for filesystem operations in host mode" do
    tmp = TestHelper.tmp_dir
    file = tmp / "test.txt"
    File.write(file, "hello sandbox none")

    executor = Autobot::Tools::SandboxExecutor.new(tmp, Autobot::Tools::Sandbox::Type::None)
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

  it "reports a program that exits non-zero as an error with its full output" do
    executor = Autobot::Tools::SandboxExecutor.new(nil)

    result = executor.exec_program("sh", ["-c", "echo out; echo err >&2; exit 3"])

    result.error?.should be_true
    result.content.should contain("out")
    result.content.should contain("STDERR:\nerr")
    result.content.should contain("Exit code: 3")
  end

  it "reports a shell command that exits non-zero as a success carrying its exit code" do
    executor = Autobot::Tools::SandboxExecutor.new(nil)

    result = executor.exec("echo out; echo err >&2; exit 3")

    result.success?.should be_true
    result.content.should contain("out")
    result.content.should contain("STDERR:\nerr")
    result.content.should contain("Exit code: 3")
  end

  it "reports a program that times out as an error with the output it produced" do
    executor = Autobot::Tools::SandboxExecutor.new(nil)

    result = executor.exec_program("sh", ["-c", "echo working; sleep 5"], timeout: 1)

    result.error?.should be_true
    result.content.should contain("Command timed out after 1 seconds")
    result.content.should contain("working")
    result.content.should_not contain("Exit code")
  end
end

describe Autobot::Tools::SandboxExecutor do
  describe "host mode path confinement" do
    it "confines reads and writes to the workspace even without roots" do
      workspace = TestHelper.tmp_dir("confine")
      outside = TestHelper.tmp_dir("outside")
      File.write(outside / "secret.txt", "secret")
      File.write(workspace / "ok.txt", "ok")
      File.write(workspace / ".env", "KEY=1")
      File.write(workspace / ".env.local", "KEY=2")
      Dir.mkdir_p(workspace / "skills")
      File.write(workspace / "skills" / "SKILL.md", "skill")
      File.symlink((outside / "secret.txt").to_s, (workspace / "link").to_s)
      File.symlink((outside / "dangling").to_s, (workspace / "dangling").to_s)
      executor = Autobot::Tools::SandboxExecutor.new(workspace, Autobot::Tools::Sandbox::Type::None)

      executor.read_file("ok.txt").content.should eq("ok")
      executor.read_file("skills/SKILL.md").content.should eq("skill")
      executor.write_file("new/dir/file.txt", "x").success?.should be_true
      File.read(workspace / "new" / "dir" / "file.txt").should eq("x")

      executor.read_file("link").access_denied?.should be_true
      executor.read_file("link").content.should contain("outside the workspace")
      executor.read_file((outside / "secret.txt").to_s).access_denied?.should be_true
      executor.read_file("~/.ssh/x").access_denied?.should be_true
      executor.write_file("../escape.txt", "x").access_denied?.should be_true
      executor.write_file("dangling", "x").access_denied?.should be_true
      File.exists?(outside / "dangling").should be_false

      executor.read_file(".env").access_denied?.should be_true
      executor.read_file(".env").content.should contain(".env files")
      executor.read_file_base64(".env.local").access_denied?.should be_true
      executor.write_file(".env", "KEY=3").access_denied?.should be_true
      File.read(workspace / ".env").should eq("KEY=1")

      listing = executor.list_dir(".").content
      listing.should contain("ok.txt")
      listing.should_not contain(".env")
    ensure
      FileUtils.rm_rf(workspace) if workspace
      FileUtils.rm_rf(outside) if outside
    end

    it "leaves everything open when no workspace is configured" do
      executor = Autobot::Tools::SandboxExecutor.new(nil, Autobot::Tools::Sandbox::Type::None)
      executor.read_file("/etc/hosts").success?.should be_true
      executor.read_file("/etc/.env").access_denied?.should be_true
    end
  end

  describe "#exec working directory" do
    it "runs host commands in the requested directory" do
      workspace = TestHelper.tmp_dir("cwd")
      Dir.mkdir_p(workspace / "sub")
      executor = Autobot::Tools::SandboxExecutor.new(workspace, Autobot::Tools::Sandbox::Type::None)

      executor.exec("pwd", cwd: (workspace / "sub").to_s).content.strip.should end_with("/sub")
    ensure
      FileUtils.rm_rf(workspace) if workspace
    end

    it "refuses a sandboxed working directory outside the workspace" do
      workspace = TestHelper.tmp_dir("cwd")
      executor = Autobot::Tools::SandboxExecutor.new(workspace, Autobot::Tools::Sandbox::Type::Bubblewrap)

      result = executor.exec("pwd", cwd: "/etc")

      result.access_denied?.should be_true
      result.content.should contain("outside the workspace")
    ensure
      FileUtils.rm_rf(workspace) if workspace
    end
  end
end
