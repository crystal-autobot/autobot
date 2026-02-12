# Security

Use this checklist before exposing Autobot to shared channels or production workloads.

## 1. Restrict Who Can Talk to the Bot

```yaml
channels:
  telegram:
    allow_from: ["@authorized_user", "123456789"]
```

For Slack, prefer mention-only behavior in group channels.

## 2. Restrict File Access

```yaml
tools:
  restrict_to_workspace: true
```

Keep the workspace scoped to a dedicated directory, not your whole home folder.

## 3. Keep Secrets Out of Files

Use environment variables for API keys:

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
```

## 4. Review Logs Regularly

```bash
# Tool activity
grep "files\.\|exec" ~/.config/autobot/logs/autobot.log

# Token usage
grep "Tokens:" ~/.config/autobot/logs/autobot.log
```

## 5. Isolate Runtime

- Run with a least-privileged user.
- Use containerization or system service boundaries.
- Store config and sessions with strict file permissions.
