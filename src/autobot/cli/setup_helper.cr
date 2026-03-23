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

      # Load exec tool patterns from configuration.
      # User deny_patterns are merged with defaults (appended, not replaced).
      # Returns {deny_patterns, allow_patterns}.
      def self.load_exec_patterns(config : Config::Config) : {Array(Regex), Array(Regex)}
        user_deny = config.tools.try(&.exec.try(&.deny_patterns)) || [] of String

        # Start with defaults and append user patterns
        deny_patterns = Tools::ExecTool::DEFAULT_DENY_PATTERNS.dup
        user_deny.each do |pat|
          deny_patterns << Regex.new(pat, Regex::Options::IGNORE_CASE)
        end

        user_allow = config.tools.try(&.exec.try(&.allow_patterns)) || [] of String
        allow_patterns = user_allow.map { |pat| Regex.new(pat, Regex::Options::IGNORE_CASE) }

        {deny_patterns, allow_patterns}
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
          provider_config, provider_name = config.match_provider
          raise "No provider configured" unless provider_config
          Providers::HttpProvider.new(
            api_key: provider_config.api_key,
            api_base: provider_config.api_base?,
            model: config.default_model,
            provider_name: provider_name,
          )
        end
      end

      # Sets up tool registry with built-in tools and MCP servers.
      # Returns {tool_registry, mcp_clients, rate_limiter}. Plugins are loaded
      # separately via `load_plugins` to avoid blocking startup.
      def self.setup_tools(config : Config::Config)
        sandbox_config = config.tools.try(&.sandbox) || "auto"

        if img = config.tools.try(&.docker_image)
          Tools::Sandbox.docker_image = img
        end
        Tools::Sandbox.sandbox_env = config.tools.try(&.sandbox_env) || [] of String
        Tools::Sandbox.resolve_sandbox_image(Config::Loader.config_dir)

        deny_patterns, allow_patterns = load_exec_patterns(config)
        rate_limiter = Tools::RateLimiter.from_config(config.tools.try(&.rate_limit))

        tool_registry = Tools.create_registry(
          workspace: config.workspace_path,
          exec_timeout: config.tools.try(&.exec.try(&.timeout)) || 60,
          exec_deny_patterns: deny_patterns,
          exec_allow_patterns: allow_patterns,
          sandbox_config: sandbox_config,
          brave_api_key: config.tools.try(&.web.try(&.search.try(&.api_key))),
          skills_dirs: [
            (config.workspace_path / "skills").to_s,
            (Config::Loader.skills_dir).to_s,
          ],
          rate_limiter: rate_limiter
        )

        register_image_tool(config, tool_registry)

        # MCP servers (started in background, tools register as they connect)
        mcp_clients = Mcp.setup(config, tool_registry)

        {tool_registry, mcp_clients, rate_limiter}
      end

      # Load and start plugins. Call after gateway is ready to avoid
      # blocking startup with plugin setup (binary checks, migrations, etc.).
      def self.load_plugins(config : Config::Config, tool_registry : Tools::Registry) : Plugins::Registry
        plugin_registry = Plugins::Registry.new
        executor = tool_registry.sandbox_executor || Tools::SandboxExecutor.new(nil)
        plugin_context = Plugins::PluginContext.new(
          config: config,
          tool_registry: tool_registry,
          workspace: config.workspace_path,
          sandbox_executor: executor
        )
        register_builtin_plugins(config)
        Plugins::Loader.load_all(plugin_registry, plugin_context)
        plugin_registry.start_all
        plugin_registry
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
      # Uses `tools.image.provider` override if set, otherwise tries
      # openai then gemini (the only providers that support image generation).
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

        IMAGE_CAPABLE_PROVIDERS.each do |name|
          if provider = config.provider_by_name(name)
            return {provider, name}
          end
        end

        {nil, nil}
      end

      IMAGE_CAPABLE_PROVIDERS = {"openai", "gemini"}

      BUILTIN_PLUGINS = {
        "sqlite"  => -> { Plugins::Builtin::SQLitePlugin.new.as(Plugins::Plugin) },
        "github"  => -> { Plugins::Builtin::GithubPlugin.new.as(Plugins::Plugin) },
        "weather" => -> { Plugins::Builtin::WeatherPlugin.new.as(Plugins::Plugin) },
      }

      # Register builtin plugins that are enabled in config (all enabled by default).
      def self.register_builtin_plugins(config : Config::Config) : Nil
        BUILTIN_PLUGINS.each do |name, factory|
          if config.plugin_enabled?(name)
            Plugins::Loader.register(factory.call)
          else
            ::Log.for("plugins").info { "Builtin plugin '#{name}' disabled by config" }
          end
        end
      end
    end
  end
end
