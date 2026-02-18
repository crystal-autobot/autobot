module Autobot
  module CLI
    # Shared setup logic for tools, plugins, and startup validation
    module SetupHelper
      # Validate configuration and fail on errors.
      # Called by both gateway and agent to ensure consistent startup checks.
      def self.validate_startup(config : Config::Config, config_path : String?) : Nil
        resolved_path = Config::Loader.resolve_display_path(config_path)
        issues = Config::Validator.validate(config, Path[resolved_path])

        warnings = issues.select { |i| i.severity == Config::Validator::Severity::Warning }
        unless warnings.empty?
          STDERR.puts "\n⚠️  Configuration warnings:"
          warnings.each { |warning| STDERR.puts "  • #{warning.message}" }
          STDERR.puts ""
        end

        errors = issues.select { |i| i.severity == Config::Validator::Severity::Error }
        unless errors.empty?
          STDERR.puts "\n❌ Configuration errors:"
          errors.each { |e| STDERR.puts "  • #{e.message}" }
          STDERR.puts "\nRun 'autobot doctor' for detailed diagnostics."
          exit 1
        end
      end

      # Validate that a provider is configured, exit if not.
      def self.validate_provider(config : Config::Config) : Nil
        provider_config, _name = config.match_provider
        bedrock_config = config.match_bedrock
        unless provider_config || bedrock_config
          STDERR.puts "Error: No API key configured."
          STDERR.puts "Set one in config.yml under providers section"
          exit 1
        end
      end

      # Creates the appropriate provider based on configuration.
      def self.create_provider(config : Config::Config) : Providers::Provider
        if bedrock = config.match_bedrock
          Providers::BedrockProvider.new(
            access_key_id: bedrock.access_key_id,
            secret_access_key: bedrock.secret_access_key,
            region: bedrock.region,
            model: config.default_model,
            session_token: bedrock.session_token,
            guardrail_id: bedrock.guardrail_id,
            guardrail_version: bedrock.guardrail_version,
          )
        else
          provider_config, _name = config.match_provider
          raise "No provider configured" unless provider_config
          Providers::HttpProvider.new(
            api_key: provider_config.api_key,
            api_base: provider_config.api_base?,
          )
        end
      end

      # Sets up tool registry with built-in tools, MCP servers, and plugins.
      # Returns {tool_registry, plugin_registry, mcp_clients}.
      def self.setup_tools(config : Config::Config, verbose : Bool = false)
        sandbox_config = config.tools.try(&.sandbox) || "auto"

        tool_registry = Tools.create_registry(
          workspace: config.workspace_path,
          exec_timeout: config.tools.try(&.exec.try(&.timeout)) || 60,
          sandbox_config: sandbox_config,
          brave_api_key: config.tools.try(&.web.try(&.search.try(&.api_key))),
          skills_dirs: [
            (config.workspace_path / "skills").to_s,
            (Config::Loader.skills_dir).to_s,
          ]
        )

        # MCP servers (started in background, tools register as they connect)
        mcp_clients = Mcp.setup(config, tool_registry)

        plugin_registry = Plugins::Registry.new
        executor = tool_registry.sandbox_executor || Tools::SandboxExecutor.new(nil)
        plugin_context = Plugins::PluginContext.new(
          config: config,
          tool_registry: tool_registry,
          workspace: config.workspace_path,
          sandbox_executor: executor
        )
        Plugins::Loader.load_all(plugin_registry, plugin_context)
        plugin_registry.start_all

        if verbose
          puts "✓ Plugins: #{plugin_registry.size} loaded"
          puts "✓ Tools: #{tool_registry.size} registered"
        end

        {tool_registry, plugin_registry, mcp_clients}
      end
    end
  end
end
