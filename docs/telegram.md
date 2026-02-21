# Telegram

Autobot connects to Telegram via the [Bot API](https://core.telegram.org/bots/api) using long polling. No webhook or public IP needed.

## Setup

### 1. Create a bot

Open Telegram and message [@BotFather](https://t.me/BotFather):

1. Send `/newbot`
2. Choose a display name (e.g. "My Autobot")
3. Choose a username (must end in `bot`, e.g. `my_autobot_bot`)
4. Copy the **bot token** (`123456:ABC-DEF...`)

### 2. Get your user ID

Message [@userinfobot](https://t.me/userinfobot) — it replies with your numeric user ID (e.g. `123456789`).

### 3. Configure

Add the token to your `.env` file:

```sh
TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
```

In `config.yml`:

```yaml
channels:
  telegram:
    enabled: true
    token: "${TELEGRAM_BOT_TOKEN}"
    allow_from: ["123456789"]  # your user ID
```

### 4. Start

```sh
autobot agent
# Should show: Telegram bot @my_autobot_bot connected
```

Open a chat with your bot in Telegram and send a message.

## Access control

`allow_from` controls who can interact with the bot. It accepts Telegram user IDs and usernames:

```yaml
# Deny all (secure default)
allow_from: []

# Allow specific users (recommended)
allow_from: ["123456789", "username"]

# Allow anyone (use with caution)
allow_from: ["*"]
```

Telegram sends both numeric user ID and username. The bot matches against both — `"123456789"` and `"johndoe"` both work.

Unauthorized users receive a friendly denial message with their user ID, so they can share it with you to be added.

## Custom commands

Add custom slash commands that appear in Telegram's command menu:

```yaml
channels:
  telegram:
    enabled: true
    token: "${TELEGRAM_BOT_TOKEN}"
    allow_from: ["123456789"]
    custom_commands:
      macros:
        summarize: "Summarize the last conversation in 3 bullet points"
        translate:
          prompt: "Translate the following to English"
          description: "Translate text to English"
      scripts:
        deploy:
          path: "/home/user/scripts/deploy.sh"
          description: "Deploy to production"
```

**Macros** send the prompt to the LLM. **Scripts** execute a shell command and return the output.

## Built-in commands

| Command | Description |
|---|---|
| `/start` | Welcome message |
| `/reset` | Clear conversation history |
| `/help` | List available commands |

## Streaming

By default, the bot waits for the full LLM response before sending it. With streaming enabled, the bot sends a placeholder message and progressively updates it as tokens arrive, so users see text appear in real time instead of waiting for the full response.

```yaml
channels:
  telegram:
    enabled: true
    token: "${TELEGRAM_BOT_TOKEN}"
    allow_from: ["123456789"]
    streaming: true
```

How it works:

- On the first token, the bot sends a plain-text message
- As more tokens arrive, the message is edited in place (~1 update/sec to respect Telegram rate limits)
- When the LLM finishes, the message gets a final edit with full HTML formatting (bold, code blocks, links, etc.)
- If the response exceeds Telegram's 4096-character limit, overflow is sent as separate messages

Streaming works with all HTTP-based providers (Anthropic, OpenAI, DeepSeek, Groq, Gemini, OpenRouter, vLLM). AWS Bedrock falls back to non-streaming behavior automatically.

## Features

- **Long polling** — no webhook or public IP needed
- **Streaming** — opt-in progressive message updates (see above)
- **Voice messages** — auto-transcribed via Whisper (requires Groq or OpenAI provider)
- **Photos** — sent as image attachments to the LLM
- **Documents** — attached to the message context
- **Typing indicators** — shows "typing..." while the LLM responds
- **Markdown rendering** — LLM responses are converted to Telegram HTML
- **Group chats** — bot responds when mentioned in groups

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `enabled` | No | `false` | Enable the Telegram channel |
| `token` | Yes | — | Bot API token from BotFather |
| `allow_from` | No | `[]` | User IDs/usernames allowed to use the bot |
| `streaming` | No | `false` | Enable progressive message updates |
| `proxy` | No | — | HTTP proxy URL for API requests |
| `custom_commands` | No | — | Custom slash commands (macros and scripts) |

## Troubleshooting

Enable debug logging:

```sh
LOG_LEVEL=DEBUG autobot agent
```

**Bot doesn't respond** — check `allow_from` contains your user ID. The log shows `Access denied for sender <id>` with the exact ID to add.

**"Telegram bot token not configured"** — token is empty. Check `.env` file and `${TELEGRAM_BOT_TOKEN}` substitution.

**Voice messages show `[voice message]`** — no Whisper provider configured. Add Groq or OpenAI provider.
