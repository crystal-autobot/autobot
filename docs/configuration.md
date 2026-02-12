# Configuration

Default config path: `~/.config/autobot/config.yml`

Config precedence:

1. `--config <path>`
2. `./config.yml`
3. `~/.config/autobot/config.yml`
4. Schema defaults

## Minimal Config

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"

agents:
  defaults:
    model: "anthropic/claude-sonnet-4-5"
```

## Providers

Supported provider blocks:

- `anthropic`
- `openai`
- `deepseek`
- `groq`
- `gemini`
- `openrouter`
- `vllm` (local/hosted OpenAI-compatible endpoint)

## Channels

```yaml
channels:
  telegram:
    enabled: false
    token: ""
    allow_from: []

  slack:
    enabled: false
    bot_token: ""
    app_token: ""
    mode: "socket"
    group_policy: "mention"

  whatsapp:
    enabled: false
    bridge_url: "ws://localhost:3001"
    allow_from: []
```

## Tools

```yaml
tools:
  restrict_to_workspace: true  # Default: true for security (sandbox file access to workspace)
  exec:
    timeout: 60
  web:
    search:
      api_key: ""
      max_results: 5
```

## Cron

```yaml
cron:
  enabled: true
  store_path: "~/.config/autobot/cron.json"
```

## Gateway

```yaml
gateway:
  host: "127.0.0.1"  # Default: localhost only (change to 0.0.0.0 for external access)
  port: 18790
```

### Full config reference

```yaml
# LLM providers (configure at least one)
providers:
  anthropic:
    api_key: "sk-ant-..."
  openai:
    api_key: "sk-..."
  deepseek:
    api_key: "..."
  groq:
    api_key: "..."
  gemini:
    api_key: "..."
  openrouter:
    api_key: "..."
  vllm:
    api_base: "http://localhost:8000"
    api_key: "token"

# Agent defaults
agents:
  defaults:
    model: "anthropic/claude-sonnet-4-5"
    max_tokens: 8192
    temperature: 0.7
    max_tool_iterations: 20
    memory_window: 50
    workspace: "~/.config/autobot/workspace"

# Chat channels
channels:
  telegram:
    enabled: true
    token: "BOT_TOKEN"
    allow_from: ["username1", "username2"]
    custom_commands:
      macros:
        summarize: "Summarize the last conversation in 3 bullet points"
        translate: "Translate the following to English"
      scripts:
        deploy: "/home/user/scripts/deploy.sh"
        status: "/home/user/scripts/check_status.sh"

  slack:
    enabled: false
    bot_token: "xoxb-..."
    app_token: "xapp-..."
    mode: "socket"
    group_policy: "mention"
    dm:
      enabled: true
      policy: "open"

  whatsapp:
    enabled: false
    bridge_url: "ws://localhost:3001"
    allow_from: ["1234567890"]

# Tool settings
tools:
  web:
    search:
      api_key: "BRAVE_API_KEY"
      max_results: 5
  exec:
    timeout: 60
  restrict_to_workspace: true  # Default: true (recommended for security)

# Cron scheduler
cron:
  enabled: true
  store_path: "~/.config/autobot/cron.json"

# Gateway API server
gateway:
  host: "127.0.0.1"  # Localhost only by default for security
  port: 18790
```
