# Plugins

Autobot plugins are Crystal classes that extend runtime behavior by registering tools and lifecycle hooks.

## Plugin Lifecycle

Each plugin can implement:

- `setup(context)`
- `start`
- `stop`

During setup, register tools through `context.tool_registry`.

## Minimal Plugin

```crystal
require "autobot"

module MyPlugin
  class Echo < Autobot::Plugins::Plugin
    def name : String
      "echo"
    end

    def description : String
      "Simple echo plugin"
    end

    def version : String
      "0.1.0"
    end

    def setup(context : Autobot::Plugins::PluginContext) : Nil
      context.tool_registry.register(EchoTool.new)
    end
  end

  class EchoTool < Autobot::Tools::Tool
    def name : String
      "echo"
    end

    def description : String
      "Echo input text"
    end

    def parameters : Autobot::Tools::ToolSchema
      Autobot::Tools::ToolSchema.new(
        properties: {
          "text" => Autobot::Tools::PropertySchema.new(
            type: "string",
            description: "Text to echo"
          ),
        },
        required: ["text"]
      )
    end

    def execute(params : Hash(String, JSON::Any)) : String
      params["text"].as_s
    end
  end
end

Autobot::Plugins::Loader.register(MyPlugin::Echo.new)
```

## Add Plugin to Your App

```crystal
require "autobot"
require "my-plugin"

Autobot.run
```

## Notes

- Plugin names should be unique.
- `Loader.register(...)` queues plugins before startup.
- `autobot status` shows loaded plugin metadata.
