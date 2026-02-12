# Examples

## Telegram Personal Assistant

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"

channels:
  telegram:
    enabled: true
    token: "<bot-token>"
    allow_from: ["@yourhandle"]
```

```bash
autobot gateway
autobot cron add -n morning -m "Morning briefing" --cron "0 8 * * *" \
  -d --channel telegram --to "@yourhandle"
```

## DevOps Helper (Skills + Scripts)

```bash
mkdir -p ~/.config/autobot/skills/devops
cat > ~/.config/autobot/skills/devops/SKILL.md <<'SKILL'
---
name: devops
description: "Deployment and operations workflows"
requires:
  bins: ["docker", "docker-compose"]
---
SKILL
```

Add executable scripts in the same folder, then ask Autobot to run those workflows from chat.

## Scheduled Standups

```bash
autobot cron add -n standup -m "Give me a daily standup summary" --cron "0 9 * * 1-5"
autobot cron list
```
