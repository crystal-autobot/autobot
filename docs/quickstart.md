# Quick Start

## 1. Install

### Option A: Build from source

```bash
make release
sudo install -m 0755 bin/autobot /usr/local/bin/autobot
```

### Option B: Docker

```bash
docker build -t autobot:latest .
docker run --rm -it \
  -v ~/.config/autobot:/root/.config/autobot \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  autobot:latest gateway
```

## 2. Initialize

```bash
autobot onboard
```

This creates `~/.config/autobot/` with:

- `config.yml`
- `workspace/`
- `sessions/`
- `skills/`
- `logs/`

## 3. Configure

Edit `~/.config/autobot/config.yml` and add at least one provider key:

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
```

You can also enable channels as needed:

```yaml
channels:
  telegram:
    enabled: true
    token: "<bot-token>"
    allow_from: ["@your_handle"]
```

## 4. Run

```bash
# Interactive terminal mode
autobot agent

# Single message
autobot agent -m "Summarize this project"

# Gateway mode (all enabled channels)
autobot gateway
```

## Next

- [Configuration](configuration.md)
- [CLI Reference](cli.md)
- [Security](security.md)
