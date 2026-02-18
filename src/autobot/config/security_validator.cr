require "./schema"
require "./validator_common"
require "../tools/sandbox"

module Autobot::Config
  # Security-focused configuration validator
  # Checks for critical security issues like plaintext secrets, insecure permissions, etc.
  module SecurityValidator
    include ValidatorCommon

    # Patterns for detecting plaintext secrets in config files
    SECRET_PATTERNS = [
      /sk-ant-[A-Za-z0-9_-]{20,}/, # Anthropic API keys
      /sk-[A-Za-z0-9]{20,}/,       # OpenAI API keys
      /xoxb-[A-Za-z0-9-]{20,}/,    # Slack bot tokens
      /xapp-[A-Za-z0-9-]{20,}/,    # Slack app tokens
      /\d{9,}:[A-Za-z0-9_-]{35}/,  # Telegram bot tokens
      /AIzaSy[A-Za-z0-9_-]{33}/,   # Google API keys
      /sk-[a-z0-9]{32}/,           # OpenRouter keys
      /gsk_[A-Za-z0-9]{20,}/,      # Groq keys
      /AKIA[A-Z0-9]{16}/,          # AWS access key IDs
    ]

    # Validate security configuration
    def self.validate(config : Config, config_path : Path) : Array(Issue)
      issues = [] of Issue

      issues.concat(check_mutually_exclusive_settings(config))
      issues.concat(check_plaintext_secrets(config_path))
      issues.concat(check_env_file_security(config_path))
      issues.concat(check_sandbox_availability(config))

      issues
    end

    # Check for mutually exclusive security settings
    private def self.check_mutually_exclusive_settings(config : Config) : Array(Issue)
      issues = [] of Issue

      issues
    end

    # Check for plaintext secrets in config file
    private def self.check_plaintext_secrets(config_path : Path) : Array(Issue)
      issues = [] of Issue

      return issues unless File.exists?(config_path)

      config_content = File.read(config_path)

      SECRET_PATTERNS.each do |pattern|
        if config_content.match(pattern)
          issues << Issue.new(
            severity: Severity::Error,
            message: "CRITICAL: Plaintext secrets detected in config.yml. " \
                     "Move all API keys and tokens to .env file. " \
                     "Use ${VARIABLE_NAME} syntax in config.yml to reference environment variables."
          )
          break # Only report once
        end
      end

      issues
    end

    # Check .env file existence and security
    private def self.check_env_file_security(config_path : Path) : Array(Issue)
      issues = [] of Issue
      env_path = config_path.parent / ".env"

      unless File.exists?(env_path)
        issues << Issue.new(
          severity: Severity::Warning,
          message: ".env file not found at #{env_path}. " \
                   "Create one to store API keys securely (use 'autobot new <name>' to generate)."
        )
        return issues
      end

      # Check .env permissions (should be 0600)
      stat = File.info(env_path)
      perms = stat.permissions.value & 0o777

      if perms != 0o600
        issues << Issue.new(
          severity: Severity::Error,
          message: "CRITICAL: .env file has insecure permissions (#{perms.to_s(8)}). " \
                   "Run: chmod 600 #{env_path}"
        )
      end

      issues
    end

    # Check sandbox availability
    private def self.check_sandbox_availability(config : Config) : Array(Issue)
      issues = [] of Issue

      sandbox_config = config.tools.try(&.sandbox) || "auto"

      # Warn if sandbox is disabled
      if sandbox_config.downcase == "none"
        issues << Issue.new(
          severity: Severity::Warning,
          message: "Sandbox disabled (sandbox: none). " \
                   "Enable sandboxing for better security ('auto', 'bubblewrap', or 'docker'). " \
                   "This prevents the LLM from accessing files outside the workspace."
        )
        return issues
      end

      # Check if sandbox tools are available when enabled
      unless Tools::Sandbox.available?
        issues << Issue.new(
          severity: Severity::Error,
          message: "CRITICAL: Sandbox enabled but no sandbox tool found. " \
                   "Install bubblewrap (sudo apt install bubblewrap) or Docker. " \
                   "See docs/security.md for installation instructions."
        )
      end

      issues
    end
  end
end
