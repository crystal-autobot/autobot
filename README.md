<p align="center">
  <img src="assets/logo.png" alt="Autobot logo" width="800">
</p>

# Autobot

**Ultra-efficient personal AI assistant powered by Crystal**

Compiled binary • Multi-provider LLM • Chat integrations • Plugin system

## Why Autobot?

**Production-grade AI automation** built with [Crystal](https://crystal-lang.org) — engineered for token efficiency, security, and reliability.

| What | How |
|------|-----|
| **🎯 Token Efficient** | Structured tool results • Memory consolidation • Minimal context overhead • Session management |
| **📊 Observable** | Status-based logging • Credential sanitization • Token tracking • Operation audit trails |
| **🔒 Secure by Default** | Workspace sandboxing • SSRF protection • Command guards • Rate limiting • 0600 file permissions |
| **⚡ Lightweight** | 2MB binary • <50MB Docker • Zero runtime deps • <100ms startup • Streaming I/O |

## ✨ Features

**Core Engine**
- Multi-provider LLM (Anthropic, OpenAI, DeepSeek, Groq, Gemini, OpenRouter, vLLM)
- JSONL sessions with memory consolidation
- Built-in tools: file ops, shell exec, web search/fetch

**Integrations**
- Chat channels: Telegram, Slack, WhatsApp
- Cron scheduler with expressions and intervals
- Plugin system for custom tools
- Bash script auto-discovery as tools

**Advanced**
- Skills: Markdown-based with frontmatter
- Custom commands: macros or bash scripts
- Subagents for parallel tasks
- Full observability: tokens, files, operations

## 🚀 Quick Start

### 1. Install

```bash
# From source
git clone https://github.com/veelenga/autobot.git
cd autobot
make install

# Or with Docker
docker pull ghcr.io/veelenga/autobot:latest
```

### 2. Initialize

```bash
autobot onboard
```

Creates `~/.config/autobot/` with config, workspace, sessions, skills, and logs.

### 3. Configure

Edit `~/.config/autobot/config.yml`:

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"

channels:
  telegram:
    enabled: true
    token: "YOUR_BOT_TOKEN"
    allow_from: ["your_username"]
```

### 4. Run

```bash
# Interactive mode
autobot agent

# Gateway (all channels)
autobot gateway

# Single command
autobot agent -m "Summarize this project"
```

**→ [Full Quick Start Guide](docs/quickstart.md)**

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [Quick Start](docs/quickstart.md) | Installation and first steps |
| [Configuration](docs/configuration.md) | Complete config reference |
| [Security](docs/security.md) | Security model and best practices |
| [Deployment](docs/deployment.md) | Production deployment with proper user/permissions |
| [CLI Reference](docs/cli.md) | All commands and options |
| [Architecture](docs/architecture.md) | System design and components |
| [Plugins](docs/plugins.md) | Building and using plugins |
| [Examples](docs/examples.md) | Use cases and code samples |
| [Development](docs/development.md) | Contributing and local setup |

## 💡 Examples

<details>
<summary><b>Telegram Bot with Custom Commands</b></summary>

```yaml
channels:
  telegram:
    enabled: true
    token: "BOT_TOKEN"
    allow_from: ["your_username"]
    custom_commands:
      macros:
        summarize: "Summarize our conversation in 3 bullet points"
        translate: "Translate the following to English"
      scripts:
        deploy: "/home/user/scripts/deploy.sh"
        status: "/home/user/scripts/system_status.sh"
```

Use `/summarize` or `/deploy` in Telegram to trigger them.

</details>

<details>
<summary><b>Cron Scheduler</b></summary>

```bash
# Daily morning greeting
autobot cron add --name "morning" \
  --message "Good morning! Here's today's summary" \
  --cron "0 9 * * *"

# Hourly reminder
autobot cron add --name "reminder" \
  --message "Stand up and stretch!" \
  --every 3600

# One-time meeting notification
autobot cron add --name "meeting" \
  --message "Team sync in 5 minutes!" \
  --at "2025-03-01T10:00:00"
```

</details>

<details>
<summary><b>Multi-Provider Setup</b></summary>

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
  openai:
    api_key: "${OPENAI_API_KEY}"
  deepseek:
    api_key: "${DEEPSEEK_API_KEY}"
  vllm:
    api_base: "http://localhost:8000"
    api_key: "token"

agents:
  defaults:
    model: "anthropic/claude-sonnet-4-5"
    max_tokens: 8192
    temperature: 0.7
```

</details>

**→ [More Examples](docs/examples.md)**

## 🔧 Development

### Prerequisites
- [Crystal](https://crystal-lang.org/install/) >= 1.10.0

### Commands

```bash
make build          # Debug binary
make release        # Optimized binary (~2MB)
make test           # Run test suite
make lint           # Run ameba linter
make format         # Format code

make docker         # Build Docker image
make release-all    # Cross-compile for all platforms
make help           # Show all targets
```

**→ [Development Guide](docs/development.md)**
