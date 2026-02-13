require "../../spec_helper"

describe Autobot::Tools::ExecTool do
  it "executes a simple command" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("echo hello")})
    result.success?.should be_true
    result.content.strip.should eq("hello")
  end

  it "blocks dangerous rm -rf command" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("rm -rf /")})
    result.access_denied?.should be_true
    result.content.should contain("Command blocked")
  end

  it "blocks fork bomb" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new(":(){ :|:& };:")})
    result.access_denied?.should be_true
    result.content.should contain("Command blocked")
  end

  it "blocks shutdown command" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("shutdown now")})
    result.access_denied?.should be_true
    result.content.should contain("Command blocked")
  end

  it "blocks dd command" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("dd if=/dev/zero of=/dev/sda")})
    result.access_denied?.should be_true
    result.content.should contain("Command blocked")
  end

  it "captures stderr" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("echo err >&2")})
    result.success?.should be_true
    result.content.should contain("STDERR")
    result.content.should contain("err")
  end

  it "reports exit code for failed commands" do
    tool = Autobot::Tools::ExecTool.new
    result = tool.execute({"command" => JSON::Any.new("false")})
    result.success?.should be_true
    result.content.should contain("Exit code:")
  end

  it "uses specified working directory" do
    tmp = TestHelper.tmp_dir
    tool = Autobot::Tools::ExecTool.new
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

  it "restricts path traversal in workspace mode" do
    tool = Autobot::Tools::ExecTool.new(restrict_to_workspace: true, working_dir: "/tmp")
    result = tool.execute({"command" => JSON::Any.new("cat ../../etc/passwd")})
    result.access_denied?.should be_true
    lower = result.content.downcase
    (lower.includes?("path traversal") || lower.includes?("blocked")).should be_true
  end

  it "has correct tool metadata" do
    tool = Autobot::Tools::ExecTool.new
    tool.name.should eq("exec")
    tool.description.should_not be_empty
    tool.parameters.required.should eq(["command"])
  end
end
