require "../../spec_helper"

private def write_script(dir : Path, body : String) : String
  path = (dir / "ola.sh").to_s
  File.write(path, "#!/bin/sh\n#{body}\n")
  File.chmod(path, 0o755)
  path
end

private def bash_tool(script_path : String) : Autobot::Tools::BashTool
  Autobot::Tools::BashTool.new(Autobot::Tools::SandboxExecutor.new(nil), script_path, "bash_ola", "Ola")
end

describe Autobot::Tools::BashTool do
  it "returns the script output when it exits zero" do
    tmp = TestHelper.tmp_dir
    tool = bash_tool(write_script(tmp, "echo '# wysłane'"))

    result = tool.execute({"args" => JSON::Any.new("odp hej")})

    result.success?.should be_true
    result.content.strip.should eq("# wysłane")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "fails with the script output when it exits non-zero" do
    tmp = TestHelper.tmp_dir
    tool = bash_tool(write_script(tmp, "echo '» Cześć'; exit 1"))

    result = tool.execute({"args" => JSON::Any.new("odp hej")})

    result.error?.should be_true
    result.content.should contain("» Cześć")
    result.content.should contain("Exit code: 1")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "fails when the script is missing" do
    tool = bash_tool("/nonexistent/ola.sh")

    tool.execute({"args" => JSON::Any.new("")}).error?.should be_true
  end
end
