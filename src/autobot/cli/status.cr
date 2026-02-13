module Autobot
  module CLI
    module Status
      def self.run(config_path : String?) : Nil
        config_file = Config::Loader.resolve_display_path(config_path)
        config_exists = File.exists?(config_file)

        puts LOGO.strip
        puts "autobot v#{VERSION} Status\n"

        mark = config_exists ? "✓" : "✗"
        puts "Config:    #{config_file} #{mark}"

        if config_exists
          config = Config::Loader.load(config_path)

          # Workspace
          workspace = config.workspace_path
          ws_mark = Dir.exists?(workspace) ? "✓" : "✗"
          puts "Workspace: #{workspace} #{ws_mark}"

          # Model
          puts "Model:     #{config.default_model}"

          # Providers
          puts "\nProviders:"
          if p = config.providers
            {% for name in %w[anthropic openai openrouter deepseek groq gemini vllm] %}
              if provider = p.{{ name.id }}
                has_key = provider.api_key != ""
                status = has_key ? "✓ configured" : "not set"
                puts "  {{ name.id }}: #{status}"
              else
                puts "  {{ name.id }}: not set"
              end
            {% end %}
          end

          # Channels
          puts "\nChannels:"
          if ch = config.channels
            tg = ch.telegram
            puts "  Telegram: #{tg.try(&.enabled?) ? "✓ enabled" : "disabled"}"
            sl = ch.slack
            puts "  Slack:    #{sl.try(&.enabled?) ? "✓ enabled" : "disabled"}"
            wa = ch.whatsapp
            puts "  WhatsApp: #{wa.try(&.enabled?) ? "✓ enabled" : "disabled"}"
          end

          # Cron
          cron_path = Config::Loader.cron_store_path
          if File.exists?(cron_path)
            cron_service = Cron::Service.new(cron_path)
            jobs = cron_service.list_jobs(include_disabled: true)
            enabled = jobs.count(&.enabled?)
            puts "\nCron: #{jobs.size} jobs (#{enabled} enabled)"
          end

          # Plugins
          plugin_registry = Plugins::Registry.new
          tool_registry = Tools::Registry.new
          context = Plugins::PluginContext.new(
            config: config,
            tool_registry: tool_registry,
            workspace: config.workspace_path
          )
          Plugins::Loader.load_all(plugin_registry, context)
          if plugin_registry.size > 0
            puts "\nPlugins: #{plugin_registry.size}"
            plugin_registry.all_metadata.each do |meta|
              puts "  #{meta["name"]} v#{meta["version"]} - #{meta["description"]}"
            end
          end
        else
          puts "\nRun 'autobot new <name>' to create a bot."
        end
      end
    end
  end
end
