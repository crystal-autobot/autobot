require "../../spec_helper"

describe Autobot::Tools::ExecTool do
  it "executes a simple command" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("echo hello")})
    result.strip.should eq("hello")
  end

  it "blocks dangerous rm -rf command" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("rm -rf /")})
    result.should contain("Error: Command blocked")
  end

  it "blocks fork bomb" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new(":(){ :|:& };:")})
    result.should contain("Error: Command blocked")
  end

  it "blocks shutdown command" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("shutdown now")})
    result.should contain("Error: Command blocked")
  end

  it "blocks dd command" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("dd if=/dev/zero of=/dev/sda")})
    result.should contain("Error: Command blocked")
  end

  it "captures stderr" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("echo err >&2")})
    result.should contain("STDERR")
    result.should contain("err")
  end

  it "reports exit code for failed commands" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("false")})
    result.should contain("Exit code:")
  end

  it "uses specified working directory" do
    tmp = TestHelper.tmp_dir
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({
      "command"     => JSON::Any.new("pwd"),
      "working_dir" => JSON::Any.new(tmp.to_s),
    })
    # On macOS /var is a symlink to /private/var, so `pwd` returns the real path
    result.strip.should end_with(File.basename(tmp.to_s))
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "restricts path traversal in workspace mode" do
    tool = Autobot::Tools::ExecTool.new(restrict_to_workspace: true, working_dir: "/tmp")
    result = tool.execute({"command" => JSON::Any.new("cat ../../etc/passwd")})
    result.should contain("Error") # Generic for security
  end

  it "has correct tool metadata" do
    tool = Autobot::Tools::ExecTool.new
    tool.name.should eq("exec")
    tool.description.should_not be_empty
    tool.parameters.required.should eq(["command"])
  end
end
