require "./plugin"
require "./registry"

module Autobot
  module Plugins
    # Loader for auto-discovering and registering plugins.
    #
    # Plugins are registered via `Loader.register` in their shard's
    # initialization code:
    #
    # ```
    # Autobot::Plugins::Loader.register(MyPlugin.new)
    # ```
    #
    # When `load_all` is called, all registered plugins are added
    # to the given registry and set up with the context.
    module Loader
      @@pending = [] of Plugin

      # Register a plugin for auto-discovery.
      # Call this at the top level of your shard to make the plugin available.
      def self.register(plugin : Plugin) : Nil
        @@pending << plugin
        Log.debug { "Plugin queued: #{plugin.name} v#{plugin.version}" }
      end

      # Load all registered plugins into the registry and set them up.
      def self.load_all(registry : Registry, context : PluginContext) : Nil
        @@pending.each do |plugin|
          registry.register(plugin)
        end
        @@pending.clear

        registry.setup_all(context)
        names = registry.plugin_names
        Log.info { "Loaded #{names.size} plugin(s): #{names.join(", ")}" }
      end

      # Get the list of pending (not yet loaded) plugins.
      def self.pending : Array(Plugin)
        @@pending
      end

      # Clear all pending plugins (for testing).
      def self.clear_pending : Nil
        @@pending.clear
      end
    end
  end
end
