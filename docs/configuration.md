# Configuration

Default config path: `./config.yml`

Config precedence:

1. `--config <path>`
2. `./config.yml`
3. Schema defaults

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
- `bedrock` (AWS Bedrock via Converse API) — **[Bedrock docs](bedrock.md)**

## Voice Transcription

Voice messages are automatically transcribed using the Whisper API when a supported provider is configured. No extra settings needed — the API key is reused from the provider config.

- **Groq** (preferred — faster, free tier): uses `whisper-large-v3-turbo`
- **OpenAI**: uses `whisper-1`

If neither Groq nor OpenAI is configured, voice messages fall back to `[voice message]` text.

## Channels

**Security Note:** `allow_from` is deny-by-default for security.

Setup guides: **[Telegram](telegram.md)** | **[Slack](slack.md)**

```yaml
channels:
  telegram:
    enabled: false
    token: ""
    # allow_from options:
    # []              - DENY ALL (secure default)
    # ["*"]           - Allow anyone (use with caution)
    # ["@user", "id"] - Allowlist specific users (recommended)
    allow_from: []

  slack:
    enabled: false
    bot_token: ""
    app_token: ""
    allow_from: []
    mode: "socket"
    group_policy: "mention"  # "mention" (secure) | "open" | "allowlist"

  whatsapp:
    enabled: false
    bridge_url: "ws://localhost:3001"  # Prefer wss:// for production
    # allow_from: []      - DENY ALL
    # allow_from: ["*"]   - Allow anyone
    # allow_from: ["num"] - Allowlist phone numbers
    allow_from: []
```

## Tools

```yaml
tools:
  sandbox: auto  # auto | bubblewrap | docker | none (default: auto)
  docker_image: "python:3.12-alpine"  # optional, default: alpine:latest
  exec:
    timeout: 60
  web:
    search:
      api_key: ""
      max_results: 5
```

When sandboxed, all shell commands run inside the sandbox (bubblewrap or Docker). The kernel enforces workspace restrictions — pipes, redirects, and other shell features are safe to use because the process cannot access files outside the workspace regardless.

## MCP (Model Context Protocol)

Connect to external MCP servers to give the LLM access to remote tools (Garmin, GitHub, etc.).

```yaml
mcp:
  servers:
    garmin:
      command: "uvx"
      args: ["--python", "3.12", "--from", "git+https://github.com/Taxuspt/garmin_mcp", "garmin-mcp"]
      env:
        GARMIN_EMAIL: "${GARMIN_EMAIL}"
    github:
      command: "npx"
      args: ["-y", "@modelcontextprotocol/server-github"]
      env:
        GITHUB_TOKEN: "${GITHUB_TOKEN}"
```

Tools are auto-discovered at startup and registered as `mcp_{server}_{tool}`. MCP servers run unsandboxed (they need network access) but with isolated env vars.

**-> [MCP Documentation](mcp.md)**

## Cron

```yaml
cron:
  enabled: true
  store_path: "./cron.json"
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
  bedrock:
    access_key_id: "${AWS_ACCESS_KEY_ID}"
    secret_access_key: "${AWS_SECRET_ACCESS_KEY}"
    region: "${AWS_REGION}"
    # guardrail_id: "abc123"
    # guardrail_version: "1"

# Agent defaults
agents:
  defaults:
    model: "anthropic/claude-sonnet-4-5"
    max_tokens: 8192
    temperature: 0.7
    max_tool_iterations: 20
    memory_window: 50
    workspace: "./workspace"

# Chat channels
channels:
  telegram:
    enabled: true
    token: "BOT_TOKEN"
    allow_from: ["username1", "username2"]
    custom_commands:
      macros:
        # Simple format (command name used as description)
        summarize: "Summarize the last conversation in 3 bullet points"
        # Rich format (with custom description shown in Telegram command menu)
        translate:
          prompt: "Translate the following to English"
          description: "Translate text to English"
      scripts:
        deploy:
          path: "/home/user/scripts/deploy.sh"
          description: "Deploy to production"
        status: "/home/user/scripts/check_status.sh"

  slack:
    enabled: false
    bot_token: "xoxb-..."
    app_token: "xapp-..."
    allow_from: ["U12345678"]
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
  sandbox: auto  # auto | bubblewrap | docker | none
  docker_image: "python:3.12-alpine"  # optional, default: alpine:latest
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
  store_path: "./cron.json"

# MCP servers (external tool providers)
mcp:
  servers:
    garmin:
      command: "uvx"
      args: ["--python", "3.12", "--from", "git+https://github.com/Taxuspt/garmin_mcp", "garmin-mcp"]
      env:
        GARMIN_EMAIL: "${GARMIN_EMAIL}"
    github:
      command: "npx"
      args: ["-y", "@modelcontextprotocol/server-github"]
      env:
        GITHUB_TOKEN: "${GITHUB_TOKEN}"

# Gateway API server
gateway:
  host: "127.0.0.1"  # Localhost only by default for security
  port: 18790
```
