require "../../spec_helper"

describe Autobot::Agent::SkillsLoader do
  it "initializes with workspace path" do
    tmp = TestHelper.tmp_dir
    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp)
    loader.should_not be_nil
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns empty skills when no skills directory" do
    tmp = TestHelper.tmp_dir
    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "nonexistent")
    skills = loader.list_skills
    skills.should be_empty
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "discovers workspace skills" do
    tmp = TestHelper.tmp_dir
    skills_dir = tmp / "skills" / "git"
    Dir.mkdir_p(skills_dir)
    File.write(skills_dir / "SKILL.md", <<-MD
    ---
    description: "Git helper"
    ---

    # Git Skill
    Use git commands...
    MD
    )

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    skills = loader.list_skills(filter_unavailable: false)
    skills.size.should eq(1)
    skills[0].name.should eq("git")
    skills[0].source.should eq("workspace")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "loads skill content by name" do
    tmp = TestHelper.tmp_dir
    skills_dir = tmp / "skills" / "docker"
    Dir.mkdir_p(skills_dir)
    File.write(skills_dir / "SKILL.md", "# Docker Skill\nManage containers")

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    content = loader.load_skill("docker")
    content.should_not be_nil
    content.try(&.includes?("Docker Skill")).should be_true
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns nil for unknown skill" do
    tmp = TestHelper.tmp_dir
    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    content = loader.load_skill("nonexistent")
    content.should be_nil
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "parses frontmatter metadata" do
    tmp = TestHelper.tmp_dir
    skills_dir = tmp / "skills" / "test_skill"
    Dir.mkdir_p(skills_dir)
    File.write(skills_dir / "SKILL.md", <<-MD
    ---
    description: "Test skill description"
    always: true
    ---

    # Test Skill
    Content here
    MD
    )

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    meta = loader.get_skill_metadata("test_skill")
    meta.description.should eq("Test skill description")
    meta.always?.should be_true
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns default metadata for skill without frontmatter" do
    tmp = TestHelper.tmp_dir
    skills_dir = tmp / "skills" / "plain"
    Dir.mkdir_p(skills_dir)
    File.write(skills_dir / "SKILL.md", "# Just content\nNo frontmatter")

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    meta = loader.get_skill_metadata("plain")
    meta.description.should be_nil
    meta.always?.should be_false
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "gets always-on skills" do
    tmp = TestHelper.tmp_dir

    # Create an always-on skill
    always_dir = tmp / "skills" / "core"
    Dir.mkdir_p(always_dir)
    File.write(always_dir / "SKILL.md", "---\nalways: true\n---\nCore skill")

    # Create a non-always skill
    optional_dir = tmp / "skills" / "optional"
    Dir.mkdir_p(optional_dir)
    File.write(optional_dir / "SKILL.md", "---\nalways: false\n---\nOptional skill")

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    always = loader.always_skills
    always.should contain("core")
    always.should_not contain("optional")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "builds skills summary XML" do
    tmp = TestHelper.tmp_dir
    skills_dir = tmp / "skills" / "test"
    Dir.mkdir_p(skills_dir)
    File.write(skills_dir / "SKILL.md", "---\ndescription: \"A test\"\n---\nContent")

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    summary = loader.build_skills_summary
    summary.should contain("<skills>")
    summary.should contain("<name>test</name>")
    summary.should contain("</skills>")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "parses tool field from frontmatter" do
    tmp = TestHelper.tmp_dir
    skills_dir = tmp / "skills" / "scheduler"
    Dir.mkdir_p(skills_dir)
    File.write(skills_dir / "SKILL.md", <<-MD
    ---
    description: "Scheduling rules"
    tool: cron
    ---

    # Scheduler Skill
    MD
    )

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    meta = loader.get_skill_metadata("scheduler")
    meta.tool.should eq("cron")
    meta.always?.should be_false
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns tool-linked skills matching given tool names" do
    tmp = TestHelper.tmp_dir

    # Skill linked to "cron" tool
    cron_dir = tmp / "skills" / "scheduler"
    Dir.mkdir_p(cron_dir)
    File.write(cron_dir / "SKILL.md", "---\ntool: cron\n---\nCron rules")

    # Skill linked to "exec" tool
    exec_dir = tmp / "skills" / "executor"
    Dir.mkdir_p(exec_dir)
    File.write(exec_dir / "SKILL.md", "---\ntool: exec\n---\nExec rules")

    # Skill with no tool link
    plain_dir = tmp / "skills" / "general"
    Dir.mkdir_p(plain_dir)
    File.write(plain_dir / "SKILL.md", "---\ndescription: General\n---\nGeneral skill")

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")

    # Only cron tool registered
    result = loader.tool_skills(["cron"])
    result.should contain("scheduler")
    result.should_not contain("executor")
    result.should_not contain("general")

    # Both tools registered
    result = loader.tool_skills(["cron", "exec"])
    result.should contain("scheduler")
    result.should contain("executor")
    result.should_not contain("general")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns empty array when no tool names given" do
    tmp = TestHelper.tmp_dir
    cron_dir = tmp / "skills" / "scheduler"
    Dir.mkdir_p(cron_dir)
    File.write(cron_dir / "SKILL.md", "---\ntool: cron\n---\nCron rules")

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    result = loader.tool_skills([] of String)
    result.should be_empty
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "caches tool skill resolution across calls" do
    tmp = TestHelper.tmp_dir

    cron_dir = tmp / "skills" / "scheduler"
    Dir.mkdir_p(cron_dir)
    File.write(cron_dir / "SKILL.md", "---\ntool: cron\n---\nCron rules")

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")

    # First call builds the cache
    result1 = loader.tool_skills(["cron"])
    result1.should contain("scheduler")

    # Remove the skill file — cache should still return it
    FileUtils.rm_rf(cron_dir)
    result2 = loader.tool_skills(["cron"])
    result2.should contain("scheduler")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns empty array when no skills match tool names" do
    tmp = TestHelper.tmp_dir
    plain_dir = tmp / "skills" / "general"
    Dir.mkdir_p(plain_dir)
    File.write(plain_dir / "SKILL.md", "---\ndescription: General\n---\nGeneral skill")

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: tmp / "no_builtin")
    result = loader.tool_skills(["cron"])
    result.should be_empty
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "workspace skills override builtin skills" do
    tmp = TestHelper.tmp_dir
    builtin = TestHelper.tmp_dir

    # Create builtin skill
    builtin_dir = builtin / "git"
    Dir.mkdir_p(builtin_dir)
    File.write(builtin_dir / "SKILL.md", "builtin git")

    # Create workspace override
    ws_dir = tmp / "skills" / "git"
    Dir.mkdir_p(ws_dir)
    File.write(ws_dir / "SKILL.md", "workspace git")

    loader = Autobot::Agent::SkillsLoader.new(workspace: tmp, builtin_skills_dir: builtin)
    skills = loader.list_skills(filter_unavailable: false)
    git_skills = skills.select { |skill_info| skill_info.name == "git" }
    git_skills.size.should eq(1)
    git_skills[0].source.should eq("workspace")
  ensure
    FileUtils.rm_rf(tmp) if tmp
    FileUtils.rm_rf(builtin) if builtin
  end
end
