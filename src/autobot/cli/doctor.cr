require "../config/validator"

module Autobot
  module CLI
    module Doctor
      def self.run(config_path : String?, strict : Bool) : Nil
        puts "🔍 Running autobot doctor...\n"

        # Resolve config path
        resolved_path = Config::Loader.resolve_display_path(config_path)
        config_file = Path[resolved_path]

        unless File.exists?(config_file)
          STDERR.puts "❌ Config file not found: #{config_file}"
          STDERR.puts "\nRun 'autobot onboard' to create a configuration."
          exit 1
        end

        puts "Checking: #{config_file}\n"

        # Load config (this also loads .env)
        begin
          config = Config::Loader.load(config_path)
        rescue ex
          STDERR.puts "❌ Failed to load config: #{ex.message}"
          exit 1
        end

        # Run validation
        issues = Config::Validator.validate(config, config_file)

        # Display results
        puts Config::Validator.format_issues(issues)

        # Determine exit code
        exit_code = if Config::Validator.has_errors?(issues)
                      1
                    elsif strict && Config::Validator.has_warnings?(issues)
                      1
                    else
                      0
                    end

        if exit_code == 0
          puts "\n✅ Configuration is healthy!"
        else
          puts "\n❌ Configuration has issues that need attention."
          if strict
            puts "(Running in --strict mode: warnings treated as errors)"
          end
        end

        exit exit_code
      end
    end
  end
end
