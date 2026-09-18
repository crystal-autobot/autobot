require "../../spec_helper"

private def write_script(dir : Path, body : String) : String
  path = (dir / "notify.sh").to_s
  File.write(path, "#!/bin/sh\n#{body}\n")
  File.chmod(path, 0o755)
  path
end

private def bash_tool(script_path : String, params = [] of Autobot::Agent::SkillParam) : Autobot::Tools::BashTool
  Autobot::Tools::BashTool.new(Autobot::Tools::SandboxExecutor.new(nil), script_path, "bash_notify", "Notify", params)
end

private def sql_params : Array(Autobot::Agent::SkillParam)
  [Autobot::Agent::SkillParam.new("sql", "one read-only statement"), Autobot::Agent::SkillParam.new("limit", "max rows")]
end

describe Autobot::Tools::BashTool do
  it "splits the args string like a shell when no parameters are declared" do
    tmp = TestHelper.tmp_dir
    tool = bash_tool(write_script(tmp, "printf '%s|' \"$#\" \"$@\""))

    result = tool.execute({"args" => JSON::Any.new("select 'a b' c")})

    result.content.strip.should eq("3|select|a b|c|")
    tool.parameters.properties.keys.should eq(["args"])
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "passes declared parameters positionally and verbatim" do
    tmp = TestHelper.tmp_dir
    tool = bash_tool(write_script(tmp, "printf '%s|' \"$#\" \"$@\""), sql_params)

    result = tool.execute({"sql" => JSON::Any.new("select 'a b' from t"), "limit" => JSON::Any.new("5")})

    result.content.strip.should eq("2|select 'a b' from t|5|")
    tool.parameters.properties.keys.should eq(["sql", "limit"])
    tool.parameters.properties["sql"].description.should eq("one read-only statement")
    tool.parameters.required.should eq(["sql", "limit"])
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "reads declared parameters from the skill next to the script" do
    tmp = TestHelper.tmp_dir
    Dir.mkdir_p((tmp / "notify").to_s)
    File.write((tmp / "notify" / "SKILL.md").to_s, "---\nname: notify\ntool: bash_notify\nparams:\n  sql: one statement\n---\n# Notify\n")

    params = Autobot::Tools::BashToolDiscovery.declared_params(tmp.to_s, "notify.sh")

    params.map(&.name).should eq(["sql"])

    params_bash = Autobot::Tools::BashToolDiscovery.declared_params(tmp.to_s, "notify.bash")

    params_bash.map(&.name).should eq(["sql"])

    Autobot::Tools::BashToolDiscovery.declared_params(tmp.to_s, "other.sh").should be_empty
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

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

  it "derives tool name and description from .bash extension" do
    executor = Autobot::Tools::SandboxExecutor.new(nil)
    tool = Autobot::Tools::BashTool.new(executor, "/tmp/scripts/deploy.bash")
    tool.name.should eq("bash_deploy")
    tool.description.should eq("Run the 'deploy' bash script.")
  end
end

describe Autobot::Tools::BashToolDiscovery do
  it "discovers both .sh and .bash scripts and ignores other extensions" do
    tmp = TestHelper.tmp_dir
    skills = tmp / "skills"
    Dir.mkdir_p(skills)

    File.write(skills / "backup.sh", "#!/bin/sh\n# Backup databases\necho backup")
    File.write(skills / "deploy.bash", "#!/bin/bash\n# Deploy cluster\necho deploy")
    File.write(skills / "notes.txt", "not a script")

    executor = Autobot::Tools::SandboxExecutor.new(nil)
    tools = Autobot::Tools::BashToolDiscovery.discover(executor, [skills.to_s])

    tool_names = tools.map(&.name).sort!
    tool_names.should eq(["bash_backup", "bash_deploy"])

    deploy_tool = tools.find! { |tool| tool.name == "bash_deploy" }
    deploy_tool.description.should eq("Deploy cluster")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
