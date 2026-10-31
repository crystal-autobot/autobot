require "../../spec_helper"
require "file_utils"

describe Autobot::Config::SecurityValidator do
  describe "SECRET_PATTERNS" do
    it "detects AWS access key IDs" do
      content = "access_key_id: AKIAIOSFODNN7EXAMPLE"
      matched = Autobot::Config::SecurityValidator::SECRET_PATTERNS.any? do |pattern|
        content.match(pattern)
      end
      matched.should be_true
    end

    it "does not match short strings starting with AKIA" do
      content = "access_key_id: AKIA123"
      matched = Autobot::Config::SecurityValidator::SECRET_PATTERNS.any? do |pattern|
        content.match(pattern)
      end
      matched.should be_false
    end

    it "detects Anthropic API keys" do
      content = "api_key: sk-ant-api03-realkey123456789012345678"
      matched = Autobot::Config::SecurityValidator::SECRET_PATTERNS.any? do |pattern|
        content.match(pattern)
      end
      matched.should be_true
    end
  end
end

private def validate_security(yaml : String, workspace : Path? = nil) : Array(Autobot::Config::ValidatorCommon::Issue)
  config = Autobot::Config::Config.from_yaml(yaml)
  if workspace
    defaults = Autobot::Config::AgentDefaults.new
    defaults.workspace = workspace.to_s
    agents = Autobot::Config::AgentsConfig.new
    agents.defaults = defaults
    config.agents = agents
  end
  Autobot::Config::SecurityValidator.validate(config, Path["/nonexistent/config.yml"])
end

private def errors_of(issues)
  issues.select(&.severity.error?).map(&.message)
end

private def warnings_of(issues)
  issues.select(&.severity.warning?).map(&.message)
end

describe Autobot::Config::SecurityValidator do
  around_each do |example|
    Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::Bubblewrap
    example.run
  ensure
    Autobot::Tools::Sandbox.detect_override = nil
  end

  describe "sandbox mode" do
    it "rejects an unknown value and lists external" do
      issues = validate_security("tools:\n  sandbox: podman\n", TestHelper.tmp_dir)
      errors_of(issues).any?(&.includes?("auto, bubblewrap, docker, external, none")).should be_true
    end

    it "warns that none enables host exec" do
      issues = validate_security("tools:\n  sandbox: none\n", TestHelper.tmp_dir)
      warnings_of(issues).any?(&.includes?("host exec enabled")).should be_true
      errors_of(issues).should be_empty
    end

    it "warns that external is not verified" do
      issues = validate_security("tools:\n  sandbox: external\n", TestHelper.tmp_dir)
      warnings_of(issues).any?(&.includes?("not verified")).should be_true
      errors_of(issues).should be_empty
    end

    it "accepts auto when a backend is present" do
      issues = validate_security("tools:\n  sandbox: auto\n", TestHelper.tmp_dir)
      issues.map(&.message).any?(&.downcase.includes?("sandbox")).should be_false
    end

    it "fails auto with no backend and names external and none" do
      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::None
      issues = validate_security("tools:\n  sandbox: auto\n", TestHelper.tmp_dir)
      message = errors_of(issues).find(&.includes?("No sandbox backend found")).should_not be_nil
      message.should contain("sandbox: external")
      message.should contain("sandbox: none")
    end
  end
end
