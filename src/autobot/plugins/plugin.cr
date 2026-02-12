require "json"
require "log"

module Autobot
  module Plugins
    Log = ::Log.for("plugins")

    # Abstract base class for Autobot plugins.
    #
    # Plugins extend the agent's capabilities by registering tools,
    # providing skills, or hooking into lifecycle events.
    #
    # Lifecycle:
    #   1. `initialize` — set up internal state
    #   2. `setup(context)` — register tools, configure settings
    #   3. `start` — begin background work (fibers, timers)
    #   4. `stop` — clean up resources
    #
    # Example:
    #
    # ```
    # class MyPlugin < Autobot::Plugins::Plugin
    #   def name : String
    #     "my_plugin"
    #   end
    #
    #   def description : String
    #     "Does something useful"
    #   end
    #
    #   def version : String
    #     "0.1.0"
    #   end
    #
    #   def setup(context : PluginContext) : Nil
    #     context.register_tool(MyTool.new)
    #   end
    # end
    # ```
    abstract class Plugin
      # Unique identifier for this plugin (snake_case).
      abstract def name : String

      # Human-readable description.
      abstract def description : String

      # Semantic version string.
      abstract def version : String

      # Called during setup to register tools and configure the plugin.
      # The default implementation is a no-op.
      def setup(context : PluginContext) : Nil
      end

      # Called when the gateway or agent starts.
      # Use this for spawning background fibers.
      def start : Nil
      end

      # Called during graceful shutdown.
      def stop : Nil
      end

      # Plugin metadata for status display.
      def metadata : Hash(String, String)
        {
          "name"        => name,
          "description" => description,
          "version"     => version,
        }
      end
    end

    # Context passed to plugins during setup.
    #
    # Provides access to the tool registry and configuration
    # so plugins can register their tools and read settings.
    class PluginContext
      getter config : Config::Config
      getter tool_registry : Tools::Registry
      getter workspace : Path

      def initialize(@config : Config::Config, @tool_registry : Tools::Registry, @workspace : Path)
      end
    end
  end
end
