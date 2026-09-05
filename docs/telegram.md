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

## Features

- **Long polling** — no webhook or public IP needed
- **Reply context** — when replying to a message, the original text is included as context so the bot understands what you're referring to
- **Voice notes** — a note recorded in the chat is transcribed via Whisper into the message text (Groq or OpenAI key, or the bot's own `transcription.api_key`); with transcription off the bot replies that it could not hear the note
- **Audio files and forwarded voice notes** — saved to the inbox as attachments; the transcript stays on the attachment, never in the message text
- **Photos** — sent as image attachments to the LLM and saved to the inbox
- **Documents** — saved to the inbox and attached to the message context
- **Typing indicators** — shows "typing..." while the LLM responds
- **Markdown rendering** — LLM responses are converted to Telegram HTML
- **Group chats** — the bot only replies when addressed: mentioned by `@username` or replied to. Other group messages are ignored (no response, no access-denied notice).
- **Forum topics** — in a group with topics enabled, a bot answers every message in the topics listed under `topics` without a mention, keeps one session per topic and replies into the same topic. See [Forum topics](#forum-topics).
- **Voice replies** — the `text_to_speech` plugin can generate spoken replies (see [Plugins](plugins.md))

### Group chat logging

Every message in a group the bot is a member of is appended to a rolling
per-chat log at `data/chat_logs/telegram_<chat_id>.log`, whether or not it
addresses the bot. The log is capped in size and only the most recent messages
are retained. The `get_recent_chat_log` tool reads these logs so the bot can
consult recent discussion. Operators should be aware this persists group
members' messages to disk; disable the `chat_log` plugin to turn it off.

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `enabled` | No | `false` | Enable the Telegram channel |
| `token` | Yes | — | Bot API token from BotFather |
| `allow_from` | No | `[]` | User IDs/usernames allowed to use the bot |
| `topics` | No | `[]` | Forum topic IDs the bot owns; it answers there without a mention |
| `proxy` | No | — | HTTP proxy URL for API requests |
| `custom_commands` | No | — | Custom slash commands (macros and scripts) |

## Forum topics

A supergroup with topics enabled behaves like several chats in one window. Give each bot its own topic:

```yaml
channels:
  telegram:
    enabled: true
    token: "${TELEGRAM_BOT_TOKEN}"
    allow_from: ["username"]
    topics: [57]
```

- The topic ID is the number at the end of the topic link, `https://t.me/c/<group>/57`.
- Messages in a listed topic are treated as addressed to the bot; other topics still need a mention. The General topic is topic 1: `topics: [1]` gives a bot the General topic, and replies there carry no thread id, as Telegram expects.
- The chat ID becomes `<group>:<topic>`, for example `-1001234567890:57`, so each topic has its own session, its own `/reset` and its own cron delivery target. Use that form as the `to` of a cron job or a message tool call to reach a topic.
- The bot must see the topic's messages: turn off privacy mode for it in BotFather (`/setprivacy`), or make it a group admin, then remove and re-add it to the group.

## Troubleshooting

Enable debug logging:

```sh
LOG_LEVEL=DEBUG autobot agent
```

**Bot doesn't respond** — check `allow_from` contains your user ID. The log shows `Access denied for sender <id>` with the exact ID to add.

**"Telegram bot token not configured"** — token is empty. Check `.env` file and `${TELEGRAM_BOT_TOKEN}` substitution.

**Bot replies that it could not hear a voice note** — transcription is off or no Whisper key is available. Add a Groq or OpenAI provider, or set `transcription.api_key`; see [Voice transcription](configuration.md#voice-transcription). `autobot doctor` shows which provider is in use.
