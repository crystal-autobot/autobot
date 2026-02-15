require "../../spec_helper"

private def create_test_executor
  Autobot::Tools::SandboxExecutor.new(nil, nil)
end

describe Autobot::Tools::ExecTool do
  it "executes a simple command" do
    tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
    result = tool.execute({"command" => JSON::Any.new("echo hello")})
    result.success?.should be_true
    result.content.strip.should eq("hello")
  end

  it "blocks dangerous rm -rf command" do
    tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
    result = tool.execute({"command" => JSON::Any.new("rm -rf /")})
    result.access_denied?.should be_true
    result.content.should contain("Command blocked")
  end

  it "blocks fork bomb" do
    tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
    result = tool.execute({"command" => JSON::Any.new(":(){ :|:& };:")})
    result.access_denied?.should be_true
    result.content.should contain("Command blocked")
  end

  it "blocks shutdown command" do
    tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
    result = tool.execute({"command" => JSON::Any.new("shutdown now")})
    result.access_denied?.should be_true
    result.content.should contain("Command blocked")
  end

  it "blocks dd command" do
    tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
    result = tool.execute({"command" => JSON::Any.new("dd if=/dev/zero of=/dev/sda")})
    result.access_denied?.should be_true
    result.content.should contain("Command blocked")
  end

  it "captures stderr" do
    tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
    result = tool.execute({"command" => JSON::Any.new("echo err >&2")})
    result.success?.should be_true
    result.content.should contain("STDERR")
    result.content.should contain("err")
  end

  it "reports exit code for failed commands" do
    tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
    result = tool.execute({"command" => JSON::Any.new("false")})
    result.success?.should be_true
    result.content.should contain("Exit code:")
  end

  it "uses specified working directory" do
    tmp = TestHelper.tmp_dir
    tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
    result = tool.execute({
      "command"     => JSON::Any.new("pwd"),
      "working_dir" => JSON::Any.new(tmp.to_s),
    })
    # On macOS /var is a symlink to /private/var, so `pwd` returns the real path
    result.success?.should be_true
    result.content.strip.should end_with(File.basename(tmp.to_s))
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "rejects sandbox with full_shell_access" do
    # When sandboxed with full_shell_access, should raise error
    expect_raises(ArgumentError, /sandbox and full_shell_access are mutually exclusive/) do
      Autobot::Tools::ExecTool.new(
        executor: create_test_executor,
        full_shell_access: true,
        sandbox_config: "auto"
      )
    end
  end

  it "has correct tool metadata" do
    tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
    tool.name.should eq("exec")
    tool.description.should_not be_empty
    tool.parameters.required.should eq(["command"])
  end

  describe "deny patterns (defense-in-depth)" do
    it "blocks ln -s (symlink creation)" do
      tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
      result = tool.execute({"command" => JSON::Any.new("ln -s / rootlink")})
      result.access_denied?.should be_true
      result.content.should contain("Command blocked")
    end

    it "blocks ln (hardlink creation)" do
      tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
      result = tool.execute({"command" => JSON::Any.new("ln /etc/passwd localfile")})
      result.access_denied?.should be_true
      result.content.should contain("Command blocked")
    end

    it "blocks cp -l (hardlink via cp)" do
      tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
      result = tool.execute({"command" => JSON::Any.new("cp -l /etc/passwd localfile")})
      result.access_denied?.should be_true
      result.content.should contain("Command blocked")
    end

    it "blocks cp --link" do
      tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
      result = tool.execute({"command" => JSON::Any.new("cp --link /etc/passwd localfile")})
      result.access_denied?.should be_true
      result.content.should contain("Command blocked")
    end
  end

  describe "sandbox integration" do
    it "allows none sandbox" do
      tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "none")
      tool.sandbox_type.should eq(Autobot::Tools::Sandbox::Type::None)
    end

    it "detects available sandbox type with auto config" do
      tool = Autobot::Tools::ExecTool.new(executor: create_test_executor, sandbox_config: "auto")
      # Should detect bubblewrap, docker, or none based on system
      tool.sandbox_type.should_not be_nil
    end
  end
end
