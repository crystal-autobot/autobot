require "../agent/loop"
require "../tools/sandbox"

module Autobot
  module CLI
    module Gateway
      def self.run(config_path : String?, port : Int32, verbose : Bool) : Nil
        config = Config::Loader.load(config_path)

        # Run security and configuration validation
        SetupHelper.validate_startup(config, config_path)
        SetupHelper.validate_provider(config)

        puts LOGO.strip
        puts "Starting autobot gateway on port #{port}...\n"

        bus = Bus::MessageBus.new
        session_manager = Session::Manager.new(config.workspace_path)

        tool_registry, plugin_registry, mcp_clients = setup_tools(config)
        cron_service = setup_cron(config, bus)
        channel_manager = setup_channels(config, bus, session_manager)

        puts "✓ Gateway ready\n"

        provider = create_provider(config)
        agent_loop = create_agent_loop(config, bus, provider, tool_registry, session_manager, cron_service)

        # Handle shutdown signals
        shutdown = -> do
          puts "\nShutting down..."
          agent_loop.stop
          cron_service.stop
          Mcp.stop_all(mcp_clients)
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

      private def self.setup_tools(config : Config::Config)
        tool_registry, plugin_registry, mcp_clients = SetupHelper.setup_tools(config, verbose: true)

        sandbox_config = config.tools.try(&.sandbox) || "auto"
        log_sandbox_info(sandbox_config)

        {tool_registry, plugin_registry, mcp_clients}
      end

      private def self.setup_cron(config : Config::Config, bus : Bus::MessageBus) : Cron::Service
        cron_store_path = Config::Loader.cron_store_path

        on_job = ->(job : Cron::CronJob) : String? do
          return nil unless job.payload.deliver?

          channel = job.payload.channel || "system"
          chat_id = job.payload.to || ""
          return nil if chat_id.empty?

          bus.publish_inbound(Bus::InboundMessage.new(
            channel: Constants::CHANNEL_SYSTEM,
            sender_id: "#{Constants::CRON_SENDER_PREFIX}#{job.id}",
            chat_id: "#{channel}:#{chat_id}",
            content: job.payload.message,
          ))
          nil
        end

        cron_service = Cron::Service.new(cron_store_path, on_job: on_job)
        cron_status = cron_service.status
        cron_jobs = cron_status["jobs"]?.try(&.as_i?) || 0

        if cron_jobs > 0
          cron_service.start
          puts "✓ Cron: #{cron_jobs} scheduled jobs"
        end

        cron_service
      end

      private def self.setup_channels(config : Config::Config, bus : Bus::MessageBus, session_manager : Session::Manager) : Channels::Manager
        channel_manager = Channels::Manager.new(config, bus, session_manager)
        channel_manager.start

        enabled = channel_manager.enabled_channels
        if !enabled.empty?
          puts "✓ Channels: #{enabled.join(", ")}"
        else
          puts "⚠ No channels enabled (check config.yml)"
        end

        channel_manager
      end

      private def self.create_provider(config : Config::Config) : Providers::HttpProvider
        provider_config, _provider_name = config.match_provider
        unless provider_config
          STDERR.puts "Error: No provider configured"
          exit 1
        end

        Providers::HttpProvider.new(
          api_key: provider_config.api_key,
          api_base: provider_config.api_base?
        )
      end

      private def self.create_agent_loop(
        config : Config::Config,
        bus : Bus::MessageBus,
        provider : Providers::HttpProvider,
        tool_registry : Tools::Registry,
        session_manager : Session::Manager,
        cron_service : Cron::Service,
      )
        sandbox_config = config.tools.try(&.sandbox) || "auto"

        Autobot::Agent::Loop.new(
          bus: bus,
          provider: provider,
          workspace: config.workspace_path,
          tools: tool_registry,
          sessions: session_manager,
          model: config.default_model,
          max_iterations: config.agents.try(&.defaults.try(&.max_tool_iterations)) || 20,
          memory_window: config.agents.try(&.defaults.try(&.memory_window)) || 50,
          cron_service: cron_service,
          brave_api_key: config.tools.try(&.web.try(&.search.try(&.api_key))),
          exec_timeout: config.tools.try(&.exec.try(&.timeout)) || 60,
          sandbox_config: sandbox_config
        )
      end

      private def self.log_sandbox_info(sandbox_config : String) : Nil
        detected_type = Tools::Sandbox.detect

        case detected_type
        when Tools::Sandbox::Type::Bubblewrap
          puts "✓ Sandbox: bubblewrap (kernel-enforced isolation)"
        when Tools::Sandbox::Type::Docker
          puts "✓ Sandbox: docker (container isolation)"
        when Tools::Sandbox::Type::None
          if sandbox_config.downcase == "none"
            puts "⚠ Sandbox: disabled (direct execution, dev only)"
          else
            STDERR.puts "⚠️  Sandbox: unavailable (install bubblewrap or docker)"
          end
        end
      end
    end
  end
end
