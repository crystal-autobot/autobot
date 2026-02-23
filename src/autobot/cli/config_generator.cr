module Autobot
  module CLI
    # Generates configuration files from setup data
    module ConfigGenerator
      # Generates .env file content
      def self.generate_env(config : InteractiveSetup::Configuration) : String
        lines = [] of String

        # Provider API key
        lines << "# LLM Provider"
        lines << "#{provider_env_var(config.provider)}=#{config.api_key}"
        lines << ""

        # Channel tokens
        unless config.channels.empty?
          lines << "# Chat Channels"
          config.channels.each do |channel|
            generate_channel_env(channel, config, lines)
          end
          lines << ""
        end

        lines.join("\n")
      end

      private def self.generate_channel_env(channel : String, config : InteractiveSetup::Configuration, lines : Array(String))
        case channel
        when "telegram"
          generate_telegram_env(config, lines)
        when "slack"
          generate_slack_env(config, lines)
        when "zulip"
          generate_zulip_env(config, lines)
        end
      end

      private def self.generate_telegram_env(config, lines)
        if token = config.telegram_token
          lines << "TELEGRAM_BOT_TOKEN=#{token}" if !token.empty?
        end
      end

      private def self.generate_slack_env(config, lines)
        if token = config.slack_bot_token
          lines << "SLACK_BOT_TOKEN=#{token}" if !token.empty?
        end
        if token = config.slack_app_token
          lines << "SLACK_APP_TOKEN=#{token}" if !token.empty?
        end
      end

      private def self.generate_zulip_env(config, lines)
        if site = config.zulip_site
          lines << "ZULIP_SITE=#{site}" if !site.empty?
        end
        if email = config.zulip_email
          lines << "ZULIP_EMAIL=#{email}" if !email.empty?
        end
        if api_key = config.zulip_api_key
          lines << "ZULIP_API_KEY=#{api_key}" if !api_key.empty?
        end
      end

      # Generates config.yml content
      def self.generate_config(config : InteractiveSetup::Configuration) : String
        defaults = Config::AgentDefaults.new

        lines = [] of String
        lines << "agents:"
        lines << "  defaults:"
        lines << "    workspace: \"./workspace\""
        lines << "    model: \"#{default_model_for(config.provider)}\""
        lines << "    max_tokens: #{defaults.max_tokens}"
        lines << "    temperature: #{defaults.temperature}"
        lines << "    memory_window: 50  # Number of messages before consolidation (0 = disabled, keeps last 10)"
        lines << ""

        lines << "providers:"
        lines << "  #{config.provider}:"
        lines << "    api_key: \"${#{provider_env_var(config.provider)}}\""
        lines << ""

        unless config.channels.empty?
          lines << "channels:"

          config.channels.each do |channel|
            lines.concat(generate_channel_config(channel, config))
          end

          lines << ""
        end

        lines << "tools:"
        lines << "  sandbox: \"auto\""
        lines << "  exec:"
        lines << "    timeout: 60"
        lines << ""

        lines << "gateway:"
        lines << "  host: \"127.0.0.1\""
        lines << "  port: 18790"

        lines.join("\n")
      end

      # Returns environment variable name for provider
      private def self.provider_env_var(provider : String) : String
        case provider
        when "anthropic"  then "ANTHROPIC_API_KEY"
        when "openai"     then "OPENAI_API_KEY"
        when "deepseek"   then "DEEPSEEK_API_KEY"
        when "groq"       then "GROQ_API_KEY"
        when "gemini"     then "GEMINI_API_KEY"
        when "openrouter" then "OPENROUTER_API_KEY"
        else
          "#{provider.upcase}_API_KEY"
        end
      end

      # Returns default model for provider
      private def self.default_model_for(provider : String) : String
        case provider
        when "anthropic"  then "anthropic/claude-sonnet-4-5"
        when "openai"     then "openai/gpt-4"
        when "deepseek"   then "deepseek/deepseek-chat"
        when "groq"       then "groq/mixtral-8x7b-32768"
        when "gemini"     then "gemini/gemini-pro"
        when "openrouter" then "openrouter/auto"
        else
          "#{provider}/default"
        end
      end

      # Generates channel-specific configuration
      private def self.generate_channel_config(
        channel : String,
        config : InteractiveSetup::Configuration,
      ) : Array(String)
        lines = [] of String

        case channel
        when "telegram"
          lines << "  telegram:"
          lines << "    enabled: true"
          lines << "    token: \"${TELEGRAM_BOT_TOKEN}\""
          lines << "    allow_from: []  # Add Telegram user IDs to enable"
        when "slack"
          lines << "  slack:"
          lines << "    enabled: true"
          lines << "    bot_token: \"${SLACK_BOT_TOKEN}\""
          lines << "    app_token: \"${SLACK_APP_TOKEN}\""
          lines << "    mode: \"socket\""
          lines << "    group_policy: \"mention\""
        when "whatsapp"
          lines << "  whatsapp:"
          lines << "    enabled: true"
          lines << "    bridge_url: \"#{config.whatsapp_bridge_url || "ws://localhost:3001"}\""
          lines << "    allow_from: []  # Add phone numbers to enable"
        when "zulip"
          lines << "  zulip:"
          lines << "    enabled: true"
          lines << "    site: \"${ZULIP_SITE}\""
          lines << "    email: \"${ZULIP_EMAIL}\""
          lines << "    api_key: \"${ZULIP_API_KEY}\""
          lines << "    allow_from: []  # Add user emails to enable"
        end

        lines
      end
    end
  end
end
