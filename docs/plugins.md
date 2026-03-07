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

## Builtin Plugins

### GitHub

Provides a `github` tool for interacting with GitHub via the `gh` CLI (issues, PRs, runs, releases). Auto-detected: registered only when `gh` is installed.

### Weather

Provides a `get_weather` tool for fetching weather data from wttr.in. No API key required.

### SQLite

Provides a `sqlite` tool for persistent structured data storage. Auto-detected: registered only when `sqlite3` is installed.

**Actions:**

| Action | Description |
|---|---|
| `query` | Execute SQL (SELECT, INSERT, UPDATE, DELETE, CREATE TABLE, etc.) |
| `schema` | Show CREATE TABLE statements and indexes |
| `tables` | List table names in a database |
| `databases` | List available databases |
| `migrate` | Apply pending migrations (use after creating new migration files) |

**Database storage:** databases are stored as `data/{name}.db`.

**Migrations:** place SQL files in `data/migrations/{db_name}/` (e.g. `data/migrations/app/001_create_users.sql`). They are auto-applied in alphabetical order on first database access and tracked in a `schema_migrations` table. Use `migrate` action to apply new migrations created during a session.

## Notes

- Plugin names should be unique.
- `Loader.register(...)` queues plugins before startup.
- `autobot status` shows loaded plugin metadata.
