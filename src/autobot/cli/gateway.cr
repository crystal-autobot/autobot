require "../agent/loop"

module Autobot
  module CLI
    module Gateway
      def self.run(config_path : String?, port : Int32, verbose : Bool) : Nil
        config = Config::Loader.load(config_path)

        provider_config, _provider_name = config.match_provider
        unless provider_config
          STDERR.puts "Error: No API key configured."
          STDERR.puts "Set one in ~/.config/autobot/config.yml under providers section"
          exit 1
        end

        puts LOGO.strip
        puts "Starting autobot gateway on port #{port}...\n"

        bus = Bus::MessageBus.new
        session_manager = Session::Manager.new(config.workspace_path)

        # Create tool registry with all built-in tools
        tool_registry = Tools.create_registry(
          workspace: config.workspace_path,
          exec_timeout: config.tools.try(&.exec.try(&.timeout)) || 60,
          restrict_exec_to_workspace: config.tools.try(&.restrict_to_workspace?) || false,
          brave_api_key: config.tools.try(&.web.try(&.search.try(&.api_key))),
          skills_dirs: [
            (config.workspace_path / "skills").to_s,
            (Config::Loader.skills_dir).to_s,
          ]
        )

        # Load plugins
        plugin_registry = Plugins::Registry.new
        plugin_context = Plugins::PluginContext.new(
          config: config,
          tool_registry: tool_registry,
          workspace: config.workspace_path
        )
        Plugins::Loader.load_all(plugin_registry, plugin_context)
        plugin_registry.start_all

        puts "✓ Plugins: #{plugin_registry.size} loaded"
        puts "✓ Tools: #{tool_registry.size} registered"

        # Setup cron service
        cron_store_path = Config::Loader.cron_store_path
        cron_service = Cron::Service.new(cron_store_path)
        cron_status = cron_service.status
        cron_jobs = cron_status["jobs"]?.try(&.as_i?) || 0
        if cron_jobs > 0
          cron_service.start
          puts "✓ Cron: #{cron_jobs} scheduled jobs"
        end

        # Start channel manager
        channel_manager = Channels::Manager.new(config, bus, session_manager)
        channel_manager.start

        enabled = channel_manager.enabled_channels
        if !enabled.empty?
          puts "✓ Channels: #{enabled.join(", ")}"
        else
          puts "⚠ No channels enabled (check config.yml)"
        end

        puts "✓ Gateway ready\n"

        # Create provider
        provider_config, _provider_name = config.match_provider
        unless provider_config
          STDERR.puts "Error: No provider configured"
          exit 1
        end

        provider = Providers::HttpProvider.new(
          api_key: provider_config.api_key,
          api_base: provider_config.api_base?
        )

        # Create and start agent loop
        agent_loop = Autobot::Agent::Loop.new(
          bus: bus,
          provider: provider,
          workspace: config.workspace_path,
          tools: tool_registry,
          sessions: session_manager,
          model: config.default_model,
          max_iterations: config.agents.try(&.defaults.try(&.max_tool_iterations)) || 20,
          memory_window: config.agents.try(&.defaults.try(&.memory_window)) || 50,
          cron_service: cron_service
        )

        # Handle shutdown signals
        shutdown = -> do
          puts "\nShutting down..."
          agent_loop.stop
          cron_service.stop
          plugin_registry.stop_all
          channel_manager.stop
          bus.stop
          exit 0
        end

        Signal::INT.trap { shutdown.call }
        Signal::TERM.trap { shutdown.call }

        # Start agent loop (processes messages from bus)
        spawn(name: "agent-loop") { agent_loop.run }

        # Block main fiber
        sleep
      end
    end
  end
end
