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
