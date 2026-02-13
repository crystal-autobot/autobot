require "./schema"
require "./validator_common"

module Autobot::Config
  # Configuration validator
  # Checks for configuration issues like missing providers, invalid channel auth, etc.
  module ConfigValidator
    include ValidatorCommon

    # Validate configuration settings
    def self.validate(config : Config) : Array(Issue)
      issues = [] of Issue

      issues.concat(check_provider_config(config))
      issues.concat(check_channel_auth(config))
      issues.concat(check_gateway_binding(config))

      issues
    end

    # Check provider configuration
    private def self.check_provider_config(config : Config) : Array(Issue)
      issues = [] of Issue

      providers = config.providers
      return issues unless providers

      has_configured_provider = false

      {% for provider in %w[anthropic openai openrouter deepseek groq gemini vllm] %}
        if provider_cfg = providers.{{ provider.id }}
          api_key = provider_cfg.api_key
          if !api_key.empty? && !api_key.includes?("${")
            has_configured_provider = true
          end
        end
      {% end %}

      unless has_configured_provider
        issues << Issue.new(
          severity: Severity::Error,
          message: "No LLM provider configured. Add at least one API key to .env file " \
                   "(e.g., ANTHROPIC_API_KEY, OPENAI_API_KEY)."
        )
      end

      issues
    end

    # Check channel authentication configuration
    private def self.check_channel_auth(config : Config) : Array(Issue)
      issues = [] of Issue

      channels = config.channels
      return issues unless channels

      if telegram = channels.telegram
        issues.concat(check_telegram_auth(telegram))
      end

      if slack = channels.slack
        issues.concat(check_slack_auth(slack))
      end

      if whatsapp = channels.whatsapp
        issues.concat(check_whatsapp_auth(whatsapp))
      end

      issues
    end

    # Check Telegram channel authentication
    private def self.check_telegram_auth(telegram : TelegramConfig) : Array(Issue)
      issues = [] of Issue
      return issues unless telegram.enabled?

      if telegram.token.empty? || telegram.token.includes?("${")
        issues << Issue.new(
          severity: Severity::Warning,
          message: "Telegram is enabled but token is not set. " \
                   "Add TELEGRAM_BOT_TOKEN to .env file."
        )
      elsif telegram.allow_from.empty?
        issues << Issue.new(
          severity: Severity::Warning,
          message: "Telegram is enabled but allow_from is empty (denies all messages). " \
                   "Add Telegram user IDs to allow_from array, or use [\"*\"] to allow all."
        )
      end

      issues
    end

    # Check Slack channel authentication
    private def self.check_slack_auth(slack : SlackConfig) : Array(Issue)
      issues = [] of Issue
      return issues unless slack.enabled?

      if slack.bot_token.empty? || slack.bot_token.includes?("${")
        issues << Issue.new(
          severity: Severity::Warning,
          message: "Slack is enabled but bot_token is not set. " \
                   "Add SLACK_BOT_TOKEN to .env file."
        )
      end

      if dm = slack.dm
        if dm.enabled? && dm.allow_from.empty? && dm.policy == "allowlist"
          issues << Issue.new(
            severity: Severity::Warning,
            message: "Slack DMs enabled with allowlist policy but allow_from is empty. " \
                     "Add Slack user IDs to allow_from array."
          )
        end
      end

      issues
    end

    # Check WhatsApp channel authentication
    private def self.check_whatsapp_auth(whatsapp : WhatsAppConfig) : Array(Issue)
      issues = [] of Issue
      return issues unless whatsapp.enabled?

      if whatsapp.allow_from.empty?
        issues << Issue.new(
          severity: Severity::Warning,
          message: "WhatsApp is enabled but allow_from is empty (denies all messages). " \
                   "Add phone numbers to allow_from array."
        )
      end

      issues
    end

    # Check gateway binding configuration
    private def self.check_gateway_binding(config : Config) : Array(Issue)
      issues = [] of Issue

      gateway = config.gateway
      return issues unless gateway

      if gateway.host == "0.0.0.0"
        issues << Issue.new(
          severity: Severity::Warning,
          message: "Gateway is bound to 0.0.0.0 (all network interfaces). " \
                   "This exposes the service to the network. " \
                   "Use '127.0.0.1' for localhost-only access."
        )
      end

      issues
    end
  end
end
