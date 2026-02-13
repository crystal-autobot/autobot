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

        def initialize(
          @provider : String,
          @api_key : String,
          @channels = [] of String,
          @telegram_token = nil,
          @slack_bot_token = nil,
          @slack_app_token = nil,
          @whatsapp_bridge_url = nil,
        )
        end
      end

      # Runs interactive setup and returns configuration
      def self.run : Configuration
        print_header
        puts ""

        provider = prompt_provider
        api_key = prompt_api_key(provider)
        channels = prompt_channels

        config = Configuration.new(provider: provider, api_key: api_key, channels: channels)

        # Prompt for channel-specific configuration
        channels.each do |channel|
          prompt_channel_config(channel, config)
        end

        config
      end

      # Prints fancy setup header
      private def self.print_header
        puts ""
        puts "  ╔═══════════════════════════════════════════════╗"
        puts "  ║                                               ║"
        puts "  ║         🤖  Autobot Interactive Setup         ║"
        puts "  ║                                               ║"
        puts "  ╚═══════════════════════════════════════════════╝"
      end

      # Prompts user to select an LLM provider
      private def self.prompt_provider : String
        puts "\n┌─ Step 1/3: LLM Provider"
        puts "│"
        PROVIDERS.each_with_index do |(key, name), index|
          puts "│  #{index + 1}. #{name}"
        end
        puts "└─"

        loop do
          print "\n  → Choice (1-#{PROVIDERS.size}): "
          input = STDIN.gets.try(&.strip)
          next unless input

          if choice = input.to_i?
            if choice >= 1 && choice <= PROVIDERS.size
              provider_key = PROVIDERS.keys[choice - 1]
              provider_name = PROVIDERS[provider_key]
              puts "  ✓ Selected: #{provider_name}\n"
              return provider_key
            end
          end

          puts "  ✗ Invalid choice. Please enter 1-#{PROVIDERS.size}."
        end
      end

      # Prompts user for API key with hidden input
      private def self.prompt_api_key(provider : String) : String
        provider_name = PROVIDERS[provider]
        puts "┌─ Step 2/3: API Key"
        puts "│"
        puts "│  Enter your #{provider_name} API key"
        puts "│  (input will be hidden)"
        puts "└─"
        print "\n  → API Key: "

        # Hide input for security
        system("stty -echo") rescue nil
        api_key = STDIN.gets.try(&.strip) || ""
        system("stty echo") rescue nil

        puts # Newline after hidden input

        if api_key.empty?
          puts "  ⚠  Warning: No API key provided. You'll need to add it to .env later.\n"
          return ""
        end

        puts "  ✓ API key saved\n"
        api_key
      end

      # Prompts user to select chat channels
      private def self.prompt_channels : Array(String)
        puts "┌─ Step 3/3: Chat Channels (optional)"
        puts "│"
        puts "│  0. None (CLI only)"
        CHANNELS.each_with_index do |(key, name), index|
          puts "│  #{index + 1}. #{name}"
        end
        puts "│"
        puts "│  Enter numbers separated by spaces (e.g., '1 2' for multiple)"
        puts "└─"
        print "\n  → Channels [0]: "

        input = STDIN.gets.try(&.strip) || "0"
        selected = [] of String

        input.split.each do |num|
          next unless choice = num.to_i?
          next if choice == 0 # Skip "None" option

          if choice >= 1 && choice <= CHANNELS.size
            selected << CHANNELS.keys[choice - 1]
          end
        end

        if selected.empty?
          puts "  ✓ CLI only mode\n"
        else
          puts "  ✓ Selected: #{selected.map { |channel_key| CHANNELS[channel_key] }.join(", ")}\n"
        end

        selected
      end

      # Prompts for channel-specific configuration
      private def self.prompt_channel_config(channel : String, config : Configuration)
        case channel
        when "telegram"
          puts "┌─ Telegram Configuration"
          puts "│"
          print "│  Bot Token: "
          config.telegram_token = STDIN.gets.try(&.strip) || ""
          puts "└─"
          puts "  ✓ Telegram configured\n"
        when "slack"
          puts "┌─ Slack Configuration"
          puts "│"
          print "│  Bot Token (xoxb-...): "
          config.slack_bot_token = STDIN.gets.try(&.strip) || ""
          print "│  App Token (xapp-...): "
          config.slack_app_token = STDIN.gets.try(&.strip) || ""
          puts "└─"
          puts "  ✓ Slack configured\n"
        when "whatsapp"
          puts "┌─ WhatsApp Configuration"
          puts "│"
          print "│  Bridge URL [ws://localhost:3001]: "
          url = STDIN.gets.try(&.strip) || ""
          config.whatsapp_bridge_url = url.empty? ? "ws://localhost:3001" : url
          puts "└─"
          puts "  ✓ WhatsApp configured\n"
        end
      end
    end
  end
end
