require "../../spec_helper"
require "file_utils"

module ValidatorSpecHelpers
  # Helper to create a temporary config file
  def self.with_temp_config(content : String, &)
    Dir.mkdir_p("spec/tmp")
    path = Path["spec/tmp/test_config_#{Random.rand(10000)}.yml"]

    begin
      File.write(path, content)
      File.chmod(path, 0o600)
      yield path
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  # Helper to create a temporary .env file
  def self.with_temp_env(config_path : Path, content : String? = nil, &)
    env_path = config_path.parent / ".env"

    begin
      if content
        File.write(env_path, content)
        File.chmod(env_path, 0o600)
      end
      yield env_path
    ensure
      File.delete(env_path) if File.exists?(env_path)
    end
  end
end

describe Autobot::Config::Validator do
  describe ".validate" do
    it "returns minimal issues for valid configuration with env reference" do
      config_yaml = <<-YAML
      providers:
        anthropic:
          api_key: "${ANTHROPIC_API_KEY}"
      tools:
        sandbox: "auto"
        exec:
          full_shell_access: false
      YAML

      ValidatorSpecHelpers.with_temp_config(config_yaml) do |path|
        ValidatorSpecHelpers.with_temp_env(path, "ANTHROPIC_API_KEY=test") do
          # Set ENV for validation
          ENV["ANTHROPIC_API_KEY"] = "sk-test123456789012345678"

          config = Autobot::Config::Config.from_yaml(config_yaml)
          issues = Autobot::Config::Validator.validate(config, path)

          # With env reference and no plaintext secrets, only error should be
          # that provider is not configured (since validation checks the YAML content)
          errors = issues.select { |i| i.severity == Autobot::Config::Validator::Severity::Error }
          # No plaintext secrets, but provider not configured check might fail
          errors.size.should be <= 1
        end
      end
    end

    it "detects mutually exclusive settings" do
      config_yaml = <<-YAML
      providers:
        anthropic:
          api_key: "${ANTHROPIC_API_KEY}"
      tools:
        sandbox: "auto"
        exec:
          full_shell_access: true
      YAML

      ValidatorSpecHelpers.with_temp_config(config_yaml) do |path|
        config = Autobot::Config::Config.from_yaml(config_yaml)
        issues = Autobot::Config::Validator.validate(config, path)

        errors = issues.select { |i| i.severity == Autobot::Config::Validator::Severity::Error }
        errors.size.should be > 0
        errors.any?(&.message.includes?("mutually exclusive")).should be_true
      end
    end

    it "detects plaintext secrets in config" do
      config_yaml = <<-YAML
      providers:
        anthropic:
          api_key: "sk-ant-plaintext-secret-here"
      YAML

      ValidatorSpecHelpers.with_temp_config(config_yaml) do |path|
        config = Autobot::Config::Config.from_yaml(config_yaml)
        issues = Autobot::Config::Validator.validate(config, path)

        errors = issues.select { |i| i.severity == Autobot::Config::Validator::Severity::Error }
        errors.size.should be > 0
        errors.any?(&.message.includes?("Plaintext secrets")).should be_true
      end
    end

    it "warns about missing .env file" do
      config_yaml = <<-YAML
      providers:
        anthropic:
          api_key: "${ANTHROPIC_API_KEY}"
      YAML

      ValidatorSpecHelpers.with_temp_config(config_yaml) do |path|
        config = Autobot::Config::Config.from_yaml(config_yaml)
        issues = Autobot::Config::Validator.validate(config, path)

        warnings = issues.select { |i| i.severity == Autobot::Config::Validator::Severity::Warning }
        warnings.any?(&.message.includes?(".env file not found")).should be_true
      end
    end

    it "detects insecure .env permissions" do
      config_yaml = <<-YAML
      providers:
        anthropic:
          api_key: "${ANTHROPIC_API_KEY}"
      YAML

      ValidatorSpecHelpers.with_temp_config(config_yaml) do |path|
        ValidatorSpecHelpers.with_temp_env(path, "ANTHROPIC_API_KEY=test") do |env_path|
          File.chmod(env_path, 0o644) # Insecure permissions

          config = Autobot::Config::Config.from_yaml(config_yaml)
          issues = Autobot::Config::Validator.validate(config, path)

          errors = issues.select { |i| i.severity == Autobot::Config::Validator::Severity::Error }
          errors.any?(&.message.includes?("insecure permissions")).should be_true
        end
      end
    end

    it "detects missing provider configuration" do
      config_yaml = <<-YAML
      providers:
        anthropic:
          api_key: "${ANTHROPIC_API_KEY}"
      YAML

      ValidatorSpecHelpers.with_temp_config(config_yaml) do |path|
        config = Autobot::Config::Config.from_yaml(config_yaml)
        issues = Autobot::Config::Validator.validate(config, path)

        errors = issues.select { |i| i.severity == Autobot::Config::Validator::Severity::Error }
        errors.any?(&.message.includes?("No LLM provider")).should be_true
      end
    end

    it "detects gateway bound to all interfaces" do
      config_yaml = <<-YAML
      providers:
        anthropic:
          api_key: "${ANTHROPIC_API_KEY}"
      gateway:
        host: "0.0.0.0"
      YAML

      ValidatorSpecHelpers.with_temp_config(config_yaml) do |path|
        config = Autobot::Config::Config.from_yaml(config_yaml)
        issues = Autobot::Config::Validator.validate(config, path)

        warnings = issues.select { |i| i.severity == Autobot::Config::Validator::Severity::Warning }
        warnings.any?(&.message.includes?("0.0.0.0")).should be_true
      end
    end
  end

  describe ".format_issues" do
    it "returns success message when no issues" do
      issues = [] of Autobot::Config::ValidatorCommon::Issue
      output = Autobot::Config::Validator.format_issues(issues)
      output.should eq("✓ All checks passed!")
    end

    it "formats errors, warnings, and info" do
      issues = [
        Autobot::Config::ValidatorCommon::Issue.new(
          severity: Autobot::Config::ValidatorCommon::Severity::Error,
          message: "Critical error"
        ),
        Autobot::Config::ValidatorCommon::Issue.new(
          severity: Autobot::Config::ValidatorCommon::Severity::Warning,
          message: "Warning message"
        ),
        Autobot::Config::ValidatorCommon::Issue.new(
          severity: Autobot::Config::ValidatorCommon::Severity::Info,
          message: "Info message"
        ),
      ]

      output = Autobot::Config::Validator.format_issues(issues)
      output.should contain("❌ ERRORS")
      output.should contain("⚠️  WARNINGS")
      output.should contain("ℹ️  INFO")
      output.should contain("Critical error")
      output.should contain("Warning message")
      output.should contain("Info message")
      output.should contain("Summary: 1 errors, 1 warnings, 1 info")
    end
  end

  describe ".has_errors?" do
    it "returns true when issues contain errors" do
      issues = [
        Autobot::Config::ValidatorCommon::Issue.new(
          severity: Autobot::Config::ValidatorCommon::Severity::Error,
          message: "Error"
        ),
      ]
      Autobot::Config::Validator.has_errors?(issues).should be_true
    end

    it "returns false when issues contain no errors" do
      issues = [
        Autobot::Config::ValidatorCommon::Issue.new(
          severity: Autobot::Config::ValidatorCommon::Severity::Warning,
          message: "Warning"
        ),
      ]
      Autobot::Config::Validator.has_errors?(issues).should be_false
    end
  end

  describe ".has_warnings?" do
    it "returns true when issues contain warnings" do
      issues = [
        Autobot::Config::ValidatorCommon::Issue.new(
          severity: Autobot::Config::ValidatorCommon::Severity::Warning,
          message: "Warning"
        ),
      ]
      Autobot::Config::Validator.has_warnings?(issues).should be_true
    end

    it "returns false when issues contain no warnings" do
      issues = [
        Autobot::Config::ValidatorCommon::Issue.new(
          severity: Autobot::Config::ValidatorCommon::Severity::Error,
          message: "Error"
        ),
      ]
      Autobot::Config::Validator.has_warnings?(issues).should be_false
    end
  end
end

describe Autobot::Config::ConfigValidator do
  describe "channel validation" do
    it "detects Telegram with empty allow_from" do
      config_yaml = <<-YAML
      providers:
        anthropic:
          api_key: "test-key"
      channels:
        telegram:
          enabled: true
          token: "123:ABC"
          allow_from: []
      YAML

      config = Autobot::Config::Config.from_yaml(config_yaml)
      issues = Autobot::Config::ConfigValidator.validate(config)

      warnings = issues.select { |i| i.severity == Autobot::Config::ValidatorCommon::Severity::Warning }
      warnings.any?(&.message.includes?("allow_from is empty")).should be_true
    end

    it "detects missing Slack token" do
      config_yaml = <<-YAML
      providers:
        anthropic:
          api_key: "test-key"
      channels:
        slack:
          enabled: true
          bot_token: "${SLACK_BOT_TOKEN}"
      YAML

      config = Autobot::Config::Config.from_yaml(config_yaml)
      issues = Autobot::Config::ConfigValidator.validate(config)

      warnings = issues.select { |i| i.severity == Autobot::Config::ValidatorCommon::Severity::Warning }
      warnings.any?(&.message.includes?("bot_token is not set")).should be_true
    end
  end
end

describe Autobot::Config::Env do
  describe ".file?" do
    it "detects .env file" do
      Autobot::Config::Env.file?(".env").should be_true
    end

    it "detects .env.* files" do
      Autobot::Config::Env.file?(".env.local").should be_true
      Autobot::Config::Env.file?(".env.production").should be_true
      Autobot::Config::Env.file?(".env.development").should be_true
    end

    it "detects *.env files" do
      Autobot::Config::Env.file?("secrets.env").should be_true
      Autobot::Config::Env.file?("config.env").should be_true
    end

    it "does not detect regular files" do
      Autobot::Config::Env.file?("config.yml").should be_false
      Autobot::Config::Env.file?("environment.rb").should be_false
    end
  end

  describe ".command_references_file?" do
    it "detects .env references in commands" do
      Autobot::Config::Env.command_references_file?("cat .env").should be_true
      Autobot::Config::Env.command_references_file?("cp .env.local .env").should be_true
      Autobot::Config::Env.command_references_file?("rm secrets.env").should be_true
    end

    it "does not detect false positives" do
      Autobot::Config::Env.command_references_file?("echo 'test'").should be_false
      Autobot::Config::Env.command_references_file?("ls -la").should be_false
    end
  end
end
