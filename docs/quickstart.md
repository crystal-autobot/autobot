# Quick Start

## 1. Install

### Option A: Homebrew (macOS)

```bash
brew tap crystal-autobot/tap
brew install autobot
```

### Option B: Download binary

```bash
# Automatic detection (Linux/macOS)
curl -L "https://github.com/crystal-autobot/autobot/releases/latest/download/autobot-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)" -o autobot
chmod +x autobot
sudo mv autobot /usr/local/bin/

# Or manually download from releases page:
# https://github.com/crystal-autobot/autobot/releases
```

### Option C: Build from source

```bash
git clone https://github.com/crystal-autobot/autobot.git
cd autobot
make release
sudo install -m 0755 bin/autobot /usr/local/bin/autobot
```

### Option D: Docker

```bash
docker pull ghcr.io/crystal-autobot/autobot:latest
docker run --rm -it \
  -v ./my-bot:/app \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  ghcr.io/crystal-autobot/autobot:latest gateway
```

## 2. Create a new bot

```bash
autobot new optimus
cd optimus
```

This creates an `optimus/` directory with the following structure:

```
optimus/
├── .env              # API keys (0600 permissions)
├── .gitignore        # Excludes secrets, sessions, logs, memory
├── config.yml        # Configuration (references .env via ${ENV_VAR})
├── sessions/         # Conversation history (JSONL)
├── logs/             # Application logs
└── workspace/        # Sandboxed LLM workspace (0700 permissions)
    ├── AGENTS.md     # Agent instructions
    ├── SOUL.md       # Personality definition
    ├── USER.md       # User preferences
    ├── memory/       # Long-term memory
    │   ├── MEMORY.md
    │   └── HISTORY.md
    └── skills/       # Custom skills
```

The name is arbitrary — use whatever you like (`autobot new my-bot`, `autobot new work-assistant`, etc.).

## 3. Configure

Edit `.env` and add at least one API key:

```bash
ANTHROPIC_API_KEY=sk-ant-...
```

The generated `config.yml` references these via `${ENV_VAR}` syntax — secrets stay in `.env`, never in config files.

To enable channels, uncomment and fill in the relevant tokens in `.env`, then update `config.yml`:

```yaml
channels:
  telegram:
    enabled: true
    token: "${TELEGRAM_BOT_TOKEN}"
    allow_from: ["your_user_id"]
```

## 4. Validate

```bash
autobot doctor
```

Checks configuration, security settings, sandbox availability, and file permissions. Use `--strict` to treat warnings as errors.

## 5. Run

```bash
# Interactive terminal mode
autobot agent

# Single message
autobot agent -m "Hello!"

# Gateway mode (all enabled channels)
autobot gateway
```

## Next

- [Configuration](configuration.md)
- [Security](security.md)
- [Deployment](deployment.md)
