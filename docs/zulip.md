# Zulip Channel

Autobot can connect to Zulip using its Real-time Events API (Long Polling).

This channel uses a bot account, so you'll need to configure a bot of
the type "Generic bot" in Zulip before Autobot can connect to it.

## Features

- **Direct Messages** — Full conversation support via private messages.
- **Security** — Email-based allowlisting to control who can interact with the bot.

## Configuration

Add a `zulip` block to the `channels` section of your `config.yml`:

```yaml
channels:
  zulip:
    enabled: true
    site: "https://zulip.example.com"
    email: "bot-email@zulip.example.com"
    api_key: "your-api-key"
    # allow_from: []          - DENY ALL (secure default)
    # allow_from: ["*"]       - Allow anyone (use with caution)
    # allow_from: ["user@example.com"] - Allowlist specific emails
    allow_from: ["you@example.com"]
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `enabled` | No | `false` | Enable the Zulip channel |
| `site` | Yes | - | Your Zulip server URL (e.g., `https://zulip.example.com`) |
| `email` | Yes | - | The email address of the Zulip bot |
| `api_key` | Yes | - | The API key for the Zulip bot |
| `allow_from` | No | `[]` | List of authorized user emails or `["*"]` for all |

## Setup Instructions

1. **Create a Bot on Zulip**:
   - Go to **Personal settings** -> **Bots** -> **Add a new bot**.
   - Choose a bot type (e.g., "Generic bot").
   - Note the bot's email address and API key.

2. **Configure Autobot**:
   - Add the `site`, `email`, and `api_key` to your `config.yml`.
   - Add your own email address to `allow_from`.

3. **Start Autobot**:
   - Run `autobot gateway`.
   - Send a direct message to your bot on Zulip.

## Limitations

- Currently only supports **private direct messages**. Stream messages are not yet supported.
- Media handling (photos, attachments) is not yet implemented for Zulip.
