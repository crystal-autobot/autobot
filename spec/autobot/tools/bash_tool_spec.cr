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

  it "derives tool name and description from .bash extension" do
    executor = Autobot::Tools::SandboxExecutor.new(nil)
    tool = Autobot::Tools::BashTool.new(executor, "/tmp/scripts/deploy.bash")
    tool.name.should eq("bash_deploy")
    tool.description.should eq("Run the 'deploy' bash script.")
  end

  it "executes a .bash script successfully" do
    tmp = TestHelper.tmp_dir
    path = (tmp / "task.bash").to_s
    File.write(path, "#!/usr/bin/bash\necho 'running bash script'\n")
    File.chmod(path, 0o755)

    executor = Autobot::Tools::SandboxExecutor.new(nil)
    tool = Autobot::Tools::BashTool.new(executor, path)
    result = tool.execute({"args" => JSON::Any.new("")})
    result.success?.should be_true
    result.content.strip.should eq("running bash script")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "identifies valid script filenames and rejects hidden files or non-scripts" do
    Autobot::Tools::BashTool.valid_script?("deploy.bash").should be_true
    Autobot::Tools::BashTool.valid_script?("backup.sh").should be_true
    Autobot::Tools::BashTool.valid_script?("script.sh.bak").should be_false
    Autobot::Tools::BashTool.valid_script?("notes.txt").should be_false
    Autobot::Tools::BashTool.valid_script?(".deploy.bash").should be_false
    Autobot::Tools::BashTool.valid_script?(".backup.sh").should be_false
    Autobot::Tools::BashTool.valid_script?(".bash").should be_false
    Autobot::Tools::BashTool.valid_script?(".sh").should be_false
  end
end

describe Autobot::Tools::BashToolDiscovery do
  it "discovers both .sh and .bash scripts and ignores other extensions" do
    tmp = TestHelper.tmp_dir
    skills = tmp / "skills"
    Dir.mkdir_p(skills)

    File.write(skills / "backup.sh", "#!/bin/sh\n# Backup databases\necho backup")
    File.write(skills / "deploy.bash", "#!/usr/bin/bash\n# Deploy cluster\necho deploy")
    File.write(skills / "notes.txt", "not a script")
    File.write(skills / "helper.py", "print('hello')")

    executor = Autobot::Tools::SandboxExecutor.new(nil)
    tools = Autobot::Tools::BashToolDiscovery.discover(executor, [skills.to_s])

    tool_names = tools.map(&.name).sort!
    tool_names.should eq(["bash_backup", "bash_deploy"])

    deploy_tool = tools.find! { |tool| tool.name == "bash_deploy" }
    deploy_tool.description.should eq("Deploy cluster")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "ignores hidden files, directories with script extensions, and duplicate tool names" do
    tmp = TestHelper.tmp_dir
    skills = tmp / "skills"
    Dir.mkdir_p(skills)
    Dir.mkdir_p(skills / "nested.bash")

    File.write(skills / "deploy.bash", "#!/usr/bin/bash\n# Deploy cluster\necho deploy")
    File.write(skills / "deploy.sh", "#!/bin/sh\n# Alternate deploy\necho deploy")
    File.write(skills / ".hidden.bash", "#!/usr/bin/bash\necho hidden")
    File.write(skills / ".bash", "#!/usr/bin/bash\necho dotbash")

    executor = Autobot::Tools::SandboxExecutor.new(nil)
    tools = Autobot::Tools::BashToolDiscovery.discover(executor, [skills.to_s])

    tool_names = tools.map(&.name).sort!
    tool_names.should eq(["bash_deploy"])
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
