module Autobot
  module CLI
    # Shared setup logic for tools and plugins
    module SetupHelper
      # Sets up tool registry with built-in tools and plugins
      def self.setup_tools(config : Config::Config, verbose : Bool = false)
        sandbox_config = config.tools.try(&.sandbox) || "auto"

        tool_registry = Tools.create_registry(
          workspace: config.workspace_path,
          exec_timeout: config.tools.try(&.exec.try(&.timeout)) || 60,
          sandbox_config: sandbox_config,
          full_shell_access: config.tools.try(&.exec.try(&.full_shell_access?)) || false,
          brave_api_key: config.tools.try(&.web.try(&.search.try(&.api_key))),
          skills_dirs: [
            (config.workspace_path / "skills").to_s,
            (Config::Loader.skills_dir).to_s,
          ]
        )

        plugin_registry = Plugins::Registry.new
        executor = tool_registry.sandbox_executor || Tools::SandboxExecutor.new(nil, nil)
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

        {tool_registry, plugin_registry}
      end
    end
  end
end
