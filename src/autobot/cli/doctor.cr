require "../config/validator"
require "../tools/sandbox"

module Autobot
  module CLI
    module Doctor
      enum Status
        Pass
        Fail
        Warn
        Skip
      end

      INDICATORS = {
        Status::Pass => "✓",
        Status::Fail => "✗",
        Status::Warn => "!",
        Status::Skip => "—",
      }

      SECURE_FILE_PERMISSIONS = 0o600

      @@io : IO = STDOUT

      def self.io : IO
        @@io
      end

      def self.io=(@@io : IO)
      end

      def self.run(config_path : String?, strict : Bool) : Nil
        errors = 0
        warnings = 0

        resolved_path = Config::Loader.resolve_display_path(config_path)
        config_file = Path[resolved_path]
        env_file = config_file.parent / ".env"

        io.puts "Autobot Doctor\n"
        io.puts "  Config  #{config_file}"
        io.puts "  Env     #{env_file}"
        io.puts ""

        # Config file exists
        unless File.exists?(config_file)
          report(Status::Fail, "Config file not found")
          hint("Run 'autobot new <name>' to create a bot")
          print_summary(1, 0, strict)
          exit 1
        end
        report(Status::Pass, "Config file found")

        # Config syntax valid
        config = begin
          Config::Loader.load(config_path, validate: false)
        rescue ex
          report(Status::Fail, "Config syntax error")
          hint(ex.message)
          print_summary(1, 0, strict)
          exit 1
        end
        report(Status::Pass, "Config syntax valid")

        # .env file
        errors, warnings = check_env_file(env_file, errors, warnings)

        # Plaintext secrets
        errors = check_plaintext_secrets(config_file, errors)

        # LLM provider
        errors = check_provider(config, errors)

        # Security settings
        errors = check_security_settings(config, errors)

        # Workspace
        errors = check_workspace(config, config_file, errors)

        # Channels
        warnings = check_channels(config, warnings)

        # Gateway
        warnings = check_gateway(config, warnings)

        print_summary(errors, warnings, strict)

        exit_code = if errors > 0
                      1
                    elsif strict && warnings > 0
                      1
                    else
                      0
                    end
        exit exit_code
      end

      def self.check_env_file(env_file : Path, errors : Int32, warnings : Int32) : Tuple(Int32, Int32)
        unless File.exists?(env_file)
          report(Status::Warn, ".env file not found")
          hint("Run 'autobot new <name>' to create a bot")
          return {errors, warnings + 1}
        end
        report(Status::Pass, ".env file found")

        perms = File.info(env_file).permissions.value & 0o777
        if perms == SECURE_FILE_PERMISSIONS
          report(Status::Pass, ".env permissions secure (#{perms.to_s(8)})")
        else
          report(Status::Fail, ".env has insecure permissions (#{perms.to_s(8)})")
          hint("Run: chmod 600 #{env_file}")
          errors += 1
        end

        {errors, warnings}
      end

      def self.check_plaintext_secrets(config_file : Path, errors : Int32) : Int32
        return errors unless File.exists?(config_file)

        content = File.read(config_file)
        has_secrets = Config::SecurityValidator::SECRET_PATTERNS.any? { |pattern| content.match(pattern) }

        if has_secrets
          report(Status::Fail, "Plaintext secrets detected in config")
          hint("Move API keys to .env and use ${VAR} syntax in config.yml")
          errors + 1
        else
          report(Status::Pass, "No plaintext secrets in config")
          errors
        end
      end

      def self.check_provider(config : Config::Config, errors : Int32) : Int32
        _provider, provider_name = config.match_provider
        if provider_name
          report(Status::Pass, "LLM provider configured (#{provider_name})")
          errors
        else
          report(Status::Fail, "No LLM provider configured")
          hint("Add an API key to .env (e.g. ANTHROPIC_API_KEY)")
          errors + 1
        end
      end

      def self.check_security_settings(config : Config::Config, errors : Int32) : Int32
        # Check sandbox availability
        errors = check_sandbox_availability(config, errors)

        errors
      end

      def self.check_sandbox_availability(config : Config::Config, errors : Int32) : Int32
        sandbox_config = config.tools.try(&.sandbox) || "auto"

        if sandbox_config.downcase == "none"
          report(Status::Warn, "Sandbox disabled (sandbox: none)")
          hint("Enable sandboxing for better security ('auto', 'bubblewrap', or 'docker')")
          return errors
        end

        unless Tools::Sandbox.available?
          report(Status::Fail, "Sandbox enabled but no sandbox tool found")
          hint("Install bubblewrap: sudo apt install bubblewrap")
          hint("Or Docker: sudo apt install docker.io")
          return errors + 1
        end

        sandbox_type = Tools::Sandbox.detect
        report(Status::Pass, "Sandbox available (#{sandbox_type.to_s.downcase})")

        errors
      end

      def self.check_workspace(config : Config::Config, config_file : Path, errors : Int32) : Int32
        workspace = config.workspace_path

        if Dir.exists?(workspace)
          report(Status::Pass, "Workspace exists (#{workspace})")
        else
          report(Status::Warn, "Workspace directory missing (#{workspace})")
          hint("It will be created on first run")
        end

        # Check if .env is inside workspace (security risk)
        env_path = config_file.parent / ".env"
        if File.exists?(env_path.to_s)
          env_real = File.realpath(env_path.to_s)
          workspace_real = File.realpath(workspace.to_s) rescue workspace.to_s

          if env_real.starts_with?(workspace_real)
            report(Status::Fail, ".env file is inside workspace directory")
            hint("Move .env outside workspace to prevent exposing secrets to the LLM")
            return errors + 1
          end
        end

        errors
      end

      def self.check_channels(config : Config::Config, warnings : Int32) : Int32
        channels = config.channels
        return warnings unless channels

        warnings = check_telegram(channels.telegram, warnings)
        warnings = check_slack(channels.slack, warnings)
        warnings = check_whatsapp(channels.whatsapp, warnings)

        warnings
      end

      def self.check_telegram(telegram : Config::TelegramConfig?, warnings : Int32) : Int32
        unless telegram && telegram.enabled?
          report(Status::Skip, "Telegram (disabled)")
          return warnings
        end

        if telegram.token.empty? || telegram.token.includes?("${")
          report(Status::Warn, "Telegram enabled but token not set")
          hint("Add TELEGRAM_BOT_TOKEN to .env")
          warnings + 1
        elsif telegram.allow_from.empty?
          report(Status::Warn, "Telegram enabled but allow_from is empty")
          hint("Add user IDs to channels.telegram.allow_from")
          warnings + 1
        else
          report(Status::Pass, "Telegram configured")
          warnings
        end
      end

      def self.check_slack(slack : Config::SlackConfig?, warnings : Int32) : Int32
        unless slack && slack.enabled?
          report(Status::Skip, "Slack (disabled)")
          return warnings
        end

        if slack.bot_token.empty? || slack.bot_token.includes?("${")
          report(Status::Warn, "Slack enabled but bot_token not set")
          hint("Add SLACK_BOT_TOKEN to .env")
          warnings + 1
        else
          report(Status::Pass, "Slack configured")
          warnings
        end
      end

      def self.check_whatsapp(whatsapp : Config::WhatsAppConfig?, warnings : Int32) : Int32
        unless whatsapp && whatsapp.enabled?
          report(Status::Skip, "WhatsApp (disabled)")
          return warnings
        end

        if whatsapp.allow_from.empty?
          report(Status::Warn, "WhatsApp enabled but allow_from is empty")
          hint("Add phone numbers to channels.whatsapp.allow_from")
          warnings + 1
        else
          report(Status::Pass, "WhatsApp configured")
          warnings
        end
      end

      def self.check_gateway(config : Config::Config, warnings : Int32) : Int32
        gateway = config.gateway
        unless gateway
          report(Status::Skip, "Gateway (not configured)")
          return warnings
        end

        if gateway.host == "0.0.0.0"
          report(Status::Warn, "Gateway bound to 0.0.0.0 (all interfaces)")
          hint("Use '127.0.0.1' for localhost-only access")
          warnings + 1
        else
          report(Status::Pass, "Gateway bound to #{gateway.host}")
          warnings
        end
      end

      def self.report(status : Status, message : String) : Nil
        io.puts "  #{INDICATORS[status]} #{message}"
      end

      def self.hint(message : String?) : Nil
        io.puts "    → #{message}" if message
      end

      def self.print_summary(errors : Int32, warnings : Int32, strict : Bool) : Nil
        io.puts ""
        if errors == 0 && warnings == 0
          io.puts "All checks passed!"
        elsif errors == 0 && !strict
          io.puts "#{pluralize("warning", warnings)}. All good otherwise!"
        else
          parts = [] of String
          parts << pluralize("error", errors) if errors > 0
          parts << pluralize("warning", warnings) if warnings > 0
          io.puts "#{parts.join(", ")} found."
          io.puts "(--strict: warnings treated as errors)" if strict && errors == 0
        end
      end

      def self.pluralize(word : String, count : Int32) : String
        "#{count} #{count == 1 ? word : "#{word}s"}"
      end
    end
  end
end
