# Plugins

Autobot plugins are Crystal classes that extend runtime behavior by registering tools and lifecycle hooks.

## Plugin Lifecycle

Each plugin can implement:

- `setup(context)`
- `start`
- `stop`

During setup, register tools through `context.tool_registry`.

## Tool capabilities

Every tool class must implement `capabilities`, which declares what the tool may do. The registry checks it against the bot's policy when the tool registers and again when it runs: a tool that needs more than the bot grants is not registered, with a log line at boot. See [Configuration](configuration.md#capabilities) for the list of classes and what the gateway grants.

```crystal
def capabilities : Autobot::Tools::Capability
  Autobot::Tools::Capability::ExternalApi
end
```

Combine classes with `|`, for example `Capability::WorkspaceRead | Capability::WorkspaceWrite` for a tool that reads and writes workspace files through `context.sandbox_executor`. A tool that only touches autobot's own state declares `Capability::None`. A tool that runs commands chosen by the model on the host declares `Capability::HostExec`, which the gateway grants only under `tools.sandbox: none`.

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

    def capabilities : Autobot::Tools::Capability
      Autobot::Tools::Capability::None
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

All builtin plugins are **enabled by default**. Disable any plugin via `config.yml`:

```yaml
plugins:
  sqlite:
    enabled: true
  github:
    enabled: true
  weather:
    enabled: false  # disable weather plugin
  system_info:
    enabled: true
  text_to_speech:
    enabled: true
  chat_log:
    enabled: true
```

Omitting the `plugins` section keeps all builtins enabled. Use `autobot doctor` to verify plugin status and dependencies.

Each builtin tool declares its capabilities:

| Plugin | Tool | Capabilities |
|---|---|---|
| github | `github` | `external_api` |
| sqlite | `sqlite` | `workspace_read`, `workspace_write` |
| weather | `get_weather` | `web_read` |
| text_to_speech | `text_to_speech` | `external_api`, `workspace_write` |
| system_info | `get_system_info` | none |
| chat_log | `get_recent_chat_log` | none |

### GitHub

Provides a `github` tool for interacting with GitHub via the `gh` CLI (issues, PRs, runs, releases). Requires `gh` to be installed. `gh` runs on the host, outside the sandbox, with your GitHub account.

### Weather

Provides a `get_weather` tool for fetching weather data from wttr.in. No API key required.

### SQLite

Provides a `sqlite` tool for persistent structured data storage. Requires `sqlite3` to be installed.

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

### System info

Provides a `get_system_info` tool that returns host metrics (CPU count, memory usage, uptime, and disk space for the workspace). Runs `df`, `free`, `uptime`, and `lscpu`, so it targets Linux hosts.

### Text to speech

Provides a `text_to_speech` tool that converts text into an OGG/Opus voice file in the workspace. Requires `gtts-cli` (`pip install gtts`) and `ffmpeg` to be installed. Voice delivery is currently supported only on the Telegram channel.

### Chat log

Provides a `get_recent_chat_log` tool for consulting the rolling log of a group chat. Logs are written only by the Telegram channel (see [Telegram](telegram.md)); on other channels the tool reports no logs.

## Notes

- Plugin names should be unique.
- Every tool class must declare `capabilities`; a tool without it does not compile.
- `Loader.register(...)` queues plugins before startup.
- `autobot status` shows loaded plugin metadata.
