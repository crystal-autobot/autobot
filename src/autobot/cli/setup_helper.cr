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
      def self.setup_tools(config : Config::Config)
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

        register_image_tool(config, tool_registry)

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

        {tool_registry, plugin_registry, mcp_clients}
      end

      # Register the image generation tool if a suitable provider is available.
      def self.register_image_tool(config : Config::Config, registry : Tools::Registry) : Nil
        image_config = config.tools.try(&.image)
        if image_config && !image_config.enabled?
          ::Log.for("SetupHelper").info { "Image generation disabled" }
          return
        end

        provider_config, provider_name = resolve_image_provider(config, image_config)
        unless provider_config && provider_name
          ::Log.for("SetupHelper").info { "Image generation unavailable (no suitable provider)" }
          return
        end

        model = image_config.try(&.model)
        size = image_config.try(&.size) || "1024x1024"

        registry.register(Tools::ImageGenerationTool.new(
          api_key: provider_config.api_key,
          provider_name: provider_name,
          model: model,
          size: size,
          api_base: provider_config.api_base?,
        ))

        ::Log.for("SetupHelper").info { "Image generation enabled (#{provider_name})" }
      end

      # Resolve the provider for image generation.
      # Uses `tools.image.provider` override if set, otherwise falls back to main provider
      # (only openai and gemini support image generation).
      private def self.resolve_image_provider(
        config : Config::Config,
        image_config : Config::ImageConfig?,
      ) : {Config::ProviderConfig?, String?}
        if override_name = image_config.try(&.provider)
          provider = config.provider_by_name(override_name)
          return {provider, override_name} if provider
          ::Log.for("SetupHelper").warn { "Image provider override '#{override_name}' not configured" }
          return {nil, nil}
        end

        # Fall back to main provider, but only if it supports image generation
        provider_config, provider_name = config.match_provider
        if provider_config && provider_name && image_capable_provider?(provider_name)
          return {provider_config, provider_name}
        end

        # Try openai, then gemini as fallbacks
        {"openai", "gemini"}.each do |name|
          if provider = config.provider_by_name(name)
            return {provider, name}
          end
        end

        {nil, nil}
      end

      private def self.image_capable_provider?(name : String) : Bool
        name == "openai" || name == "gemini"
      end
    end
  end
end
