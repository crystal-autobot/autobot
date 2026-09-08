require "../../spec_helper"

private def write_script(dir : Path, body : String) : String
  path = (dir / "notify.sh").to_s
  File.write(path, "#!/bin/sh\n#{body}\n")
  File.chmod(path, 0o755)
  path
end

private def bash_tool(script_path : String) : Autobot::Tools::BashTool
  Autobot::Tools::BashTool.new(Autobot::Tools::SandboxExecutor.new(nil), script_path, "bash_notify", "Notify")
end

describe Autobot::Tools::BashTool do
  it "returns the script output when it exits zero" do
    tmp = TestHelper.tmp_dir
    tool = bash_tool(write_script(tmp, "echo '# posted'"))

    result = tool.execute({"args" => JSON::Any.new("odp hej")})

    result.success?.should be_true
    result.content.strip.should eq("# posted")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "fails with the script output when it exits non-zero" do
    tmp = TestHelper.tmp_dir
    tool = bash_tool(write_script(tmp, "echo 'could not post'; exit 1"))

    result = tool.execute({"args" => JSON::Any.new("odp hej")})

    result.error?.should be_true
    result.content.should contain("could not post")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "fails when the script is missing" do
    tool = bash_tool("/nonexistent/notify.sh")

    tool.execute({"args" => JSON::Any.new("")}).error?.should be_true
  end
end
