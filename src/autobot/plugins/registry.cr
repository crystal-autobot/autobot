require "./plugin"

module Autobot
  module Plugins
    # Registry for managing loaded plugins.
    #
    # Handles plugin registration, lifecycle, and lookup.
    class Registry
      @plugins : Hash(String, Plugin) = {} of String => Plugin

      # Register a plugin. Replaces any existing plugin with the same name.
      def register(plugin : Plugin) : Nil
        if @plugins.has_key?(plugin.name)
          Log.warn { "Replacing existing plugin: #{plugin.name}" }
        end
        @plugins[plugin.name] = plugin
        Log.info { "Registered plugin: #{plugin.name} v#{plugin.version}" }
      end

      # Setup all registered plugins with the given context.
      def setup_all(context : PluginContext) : Nil
        @plugins.each_value do |plugin|
          begin
            plugin.setup(context)
            Log.info { "Plugin setup complete: #{plugin.name}" }
          rescue ex
            Log.error { "Plugin setup failed for #{plugin.name}: #{ex.message}" }
          end
        end
      end

      # Start all registered plugins.
      def start_all : Nil
        @plugins.each_value do |plugin|
          begin
            plugin.start
          rescue ex
            Log.error { "Plugin start failed for #{plugin.name}: #{ex.message}" }
          end
        end
      end

      # Stop all registered plugins in reverse order.
      def stop_all : Nil
        @plugins.values.reverse_each do |plugin|
          begin
            plugin.stop
          rescue ex
            Log.error { "Plugin stop failed for #{plugin.name}: #{ex.message}" }
          end
        end
      end

      # Get a plugin by name.
      def get(name : String) : Plugin?
        @plugins[name]?
      end

      # Check if a plugin is registered.
      def has?(name : String) : Bool
        @plugins.has_key?(name)
      end

      # List all registered plugin names.
      def plugin_names : Array(String)
        @plugins.keys
      end

      # Get metadata for all plugins (for status display).
      def all_metadata : Array(Hash(String, String))
        @plugins.values.map(&.metadata)
      end

      # Number of registered plugins.
      def size : Int32
        @plugins.size
      end
    end
  end
end
