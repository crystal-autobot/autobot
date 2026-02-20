module Autobot
  module CLI
    # Interactive configuration setup for new bot instances
    module InteractiveSetup
      # Supported LLM providers
      PROVIDERS = {
        "anthropic"  => "Anthropic (Claude)",
        "openai"     => "OpenAI (GPT)",
        "deepseek"   => "DeepSeek",
        "groq"       => "Groq",
        "gemini"     => "Google Gemini",
        "openrouter" => "OpenRouter",
        "bedrock"    => "AWS Bedrock",
      }

      # Supported chat channels
      CHANNELS = {
        "telegram" => "Telegram",
        "slack"    => "Slack",
        "whatsapp" => "WhatsApp",
      }

      # Configuration collected from user
      class Configuration
        property provider : String
        property api_key : String
        property channels : Array(String)
        property telegram_token : String?
        property slack_bot_token : String?
        property slack_app_token : String?
        property whatsapp_bridge_url : String?
        property aws_access_key_id : String?
        property aws_secret_access_key : String?
        property aws_region : String?

        def initialize(
          @provider : String,
          @api_key : String,
          @channels = [] of String,
          @telegram_token = nil,
          @slack_bot_token = nil,
          @slack_app_token = nil,
          @whatsapp_bridge_url = nil,
          @aws_access_key_id = nil,
          @aws_secret_access_key = nil,
          @aws_region = nil,
        )
        end
      end

      # Runs interactive setup and returns configuration
      def self.run(input : IO = STDIN, output : IO = STDOUT) : Configuration
        print_header(output)
        output.puts ""

        provider = prompt_provider(input, output)

        config = if provider == "bedrock"
                   prompt_bedrock_setup(input, output, provider)
                 else
                   api_key = prompt_api_key(provider, input, output)
                   Configuration.new(provider: provider, api_key: api_key)
                 end

        channels = prompt_channels(input, output)
        config.channels = channels

        # Prompt for channel-specific configuration
        channels.each do |channel|
          prompt_channel_config(channel, config, input, output)
        end

        config
      end

      # Prints setup header
      private def self.print_header(output : IO)
        output.puts CLI::LOGO
        output.puts ""
      end

      # Prompts user to select an LLM provider
      def self.prompt_provider(input : IO, output : IO) : String
        output.puts "\n[1/3] LLM Provider"
        output.puts ""
        PROVIDERS.each_with_index do |(key, name), index|
          output.puts "  #{index + 1}. #{name}"
        end

        loop do
          output.print "\n→ Choice (1-#{PROVIDERS.size}): "
          output.flush
          user_input = input.gets.try(&.strip)
          next unless user_input

          if choice = user_input.to_i?
            if choice >= 1 && choice <= PROVIDERS.size
              provider_key = PROVIDERS.keys[choice - 1]
              provider_name = PROVIDERS[provider_key]
              output.puts "✓ #{provider_name}\n"
              return provider_key
            end
          end

          output.puts "✗ Invalid choice. Please enter 1-#{PROVIDERS.size}."
        end
      end

      # Prompts user for API key with hidden input
      private def self.prompt_api_key(provider : String, input : IO, output : IO) : String
        provider_name = PROVIDERS[provider]
        output.puts "[2/3] API Key"
        output.puts ""
        output.puts "Enter your #{provider_name} API key (input hidden):"
        output.print "→ "
        output.flush

        api_key = read_hidden_input(input, output)

        if api_key.empty?
          output.puts "⚠  No API key provided. Add it to .env later.\n"
          return ""
        end

        output.puts "✓ API key saved\n"
        api_key
      end

      # Prompts for AWS Bedrock credentials and returns a Configuration
      private def self.prompt_bedrock_setup(input : IO, output : IO, provider : String) : Configuration
        output.puts "[2/3] AWS Credentials"
        output.puts ""

        output.puts "Enter your AWS Access Key ID:"
        output.print "→ "
        output.flush
        access_key = input.gets.try(&.strip) || ""

        output.puts "Enter your AWS Secret Access Key (input hidden):"
        output.print "→ "
        output.flush
        secret_key = read_hidden_input(input, output)

        output.puts "Enter your AWS Region [us-east-1]:"
        output.print "→ "
        output.flush
        region = input.gets.try(&.strip) || ""
        region = "us-east-1" if region.empty?

        if access_key.empty? || secret_key.empty?
          output.puts "⚠  Incomplete AWS credentials. Add them to .env later.\n"
        else
          output.puts "✓ AWS credentials saved (#{region})\n"
        end

        Configuration.new(
          provider: provider,
          api_key: "",
          aws_access_key_id: access_key,
          aws_secret_access_key: secret_key,
          aws_region: region,
        )
      end

      private def self.read_hidden_input(input : IO, output : IO) : String
        hide_input = input == STDIN
        system("stty -echo") rescue nil if hide_input
        value = input.gets.try(&.strip) || ""
        system("stty echo") rescue nil if hide_input
        output.puts # Newline after hidden input
        value
      end

      # Prompts user to select chat channels
      def self.prompt_channels(input : IO, output : IO) : Array(String)
        output.puts "[3/3] Chat Channels (optional)"
        output.puts ""
        output.puts "  0. None (CLI only)"
        CHANNELS.each_with_index do |(key, name), index|
          output.puts "  #{index + 1}. #{name}"
        end
        output.puts ""
        output.puts "Enter numbers separated by spaces (e.g., '1 2' for multiple):"
        output.print "→ "
        output.flush

        user_input = input.gets.try(&.strip) || "0"
        selected = [] of String

        user_input.split.each do |num|
          next unless choice = num.to_i?
          next if choice == 0 # Skip "None" option

          if choice >= 1 && choice <= CHANNELS.size
            selected << CHANNELS.keys[choice - 1]
          end
        end

        if selected.empty?
          output.puts "✓ CLI only\n"
        else
          output.puts "✓ #{selected.map { |channel_key| CHANNELS[channel_key] }.join(", ")}\n"
        end

        selected
      end

      # Prompts for channel-specific configuration
      def self.prompt_channel_config(channel : String, config : Configuration, input : IO, output : IO)
        case channel
        when "telegram"
          output.puts "━" * 50
          output.puts "Telegram Configuration"
          output.puts ""
          output.print "  Bot Token: "
          output.flush
          config.telegram_token = input.gets.try(&.strip) || ""
          output.puts "  ✓ Configured\n"
        when "slack"
          output.puts "━" * 50
          output.puts "Slack Configuration"
          output.puts ""
          output.print "  Bot Token (xoxb-...): "
          output.flush
          config.slack_bot_token = input.gets.try(&.strip) || ""
          output.print "  App Token (xapp-...): "
          output.flush
          config.slack_app_token = input.gets.try(&.strip) || ""
          output.puts "  ✓ Configured\n"
        when "whatsapp"
          output.puts "━" * 50
          output.puts "WhatsApp Configuration"
          output.puts ""
          output.print "  Bridge URL [ws://localhost:3001]: "
          output.flush
          url = input.gets.try(&.strip) || ""
          config.whatsapp_bridge_url = url.empty? ? "ws://localhost:3001" : url
          output.puts "  ✓ Configured\n"
        end
      end
    end
  end
end
