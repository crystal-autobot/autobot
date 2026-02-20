# Slack

Autobot connects to Slack via [Socket Mode](https://api.slack.com/apis/socket-mode) (WebSocket). No public IP or webhook URL needed.

## Setup

### 1. Create a Slack app

Go to [api.slack.com/apps](https://api.slack.com/apps) > **Create New App** > **From scratch**. Choose a name and workspace.

### 2. Enable Socket Mode

In your app settings: **Socket Mode** > toggle **Enable Socket Mode** > name the token (e.g. "autobot") > copy the **App Token** (`xapp-...`).

### 3. Add bot scopes

Go to **OAuth & Permissions** > **Scopes** > **Bot Token Scopes** and add:

| Scope | Purpose |
|---|---|
| `app_mentions:read` | Respond to @mentions |
| `chat:write` | Send messages |
| `reactions:write` | Add emoji reactions |
| `im:history` | Read DMs (optional) |
| `channels:history` | Read channel messages (optional, for `open` policy) |

### 4. Subscribe to events

Go to **Event Subscriptions** > toggle **Enable Events** > **Subscribe to bot events** and add:

| Event | Purpose |
|---|---|
| `app_mention` | Respond to @mentions in channels |
| `message.im` | Respond to direct messages (optional) |
| `message.channels` | Respond to all channel messages (optional, for `open` policy) |

### 5. Enable DMs (optional)

Go to **App Home** > **Show Tabs** > enable **Messages Tab** > check **"Allow users to send Slash commands and messages from the messages tab"**.

### 6. Install the app

Go to **Install App** > **Install to Workspace** > authorize > copy the **Bot Token** (`xoxb-...`).

> After adding new scopes or events, you must **reinstall** the app for changes to take effect.

### 7. Get your Slack user ID

Click your profile picture in Slack > **Profile** > click the three dots (**...**) > **Copy member ID** (e.g. `U02FFF68WGL`).

### 8. Configure

Add tokens to your `.env` file:

```sh
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
```

In `config.yml`:

```yaml
channels:
  slack:
    enabled: true
    bot_token: "${SLACK_BOT_TOKEN}"
    app_token: "${SLACK_APP_TOKEN}"
    allow_from: ["U02FFF68WGL"]  # your Slack user ID
    group_policy: "mention"
```

### 9. Start

```sh
autobot agent
# Should show: Slack bot connected as U...
#              Connecting to Slack WebSocket...
```

Invite the bot to a channel (`/invite @your-bot`) and mention it to start chatting.

## Access control

Two layers of access control:

### User allowlist (`allow_from`)

Controls which Slack users can interact with the bot at all — across channels and DMs:

```yaml
# Deny all (secure default)
allow_from: []

# Allow specific users (recommended)
allow_from: ["U02FFF68WGL", "U0AG5U7JLB0"]

# Allow anyone (use with caution)
allow_from: ["*"]
```

### Channel policy (`group_policy`)

Controls how the bot responds in channels:

| Policy | Behavior |
|---|---|
| `"mention"` | Only responds to @mentions (default, secure) |
| `"open"` | Responds to all messages in channels |
| `"allowlist"` | Only responds in channels listed in `group_allow_from` |

```yaml
# Only respond in specific channels
group_policy: "allowlist"
group_allow_from: ["C01ABC123", "C02DEF456"]
```

### DM policy

Controls direct message behavior:

```yaml
dm:
  enabled: true
  policy: "open"          # "open" or "allowlist"
  allow_from: ["U12345"]  # required if policy is "allowlist"
```

DMs are disabled by default. When enabled with `allowlist` policy, only users in `dm.allow_from` can DM the bot.

## Features

- **Socket Mode** — WebSocket connection, no public IP needed
- **@mention responses** — responds when mentioned in channels
- **Thread support** — replies in threads for channel messages
- **DM support** — configurable direct message handling
- **Emoji reactions** — adds :eyes: to received messages
- **Auto-reconnect** — reconnects automatically on disconnection

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `enabled` | No | `false` | Enable the Slack channel |
| `bot_token` | Yes | — | Bot User OAuth Token (`xoxb-...`) |
| `app_token` | Yes | — | App-Level Token (`xapp-...`) |
| `allow_from` | No | `[]` | Slack user IDs allowed to use the bot |
| `mode` | No | `"socket"` | Connection mode |
| `group_policy` | No | `"mention"` | Channel response policy |
| `group_allow_from` | No | `[]` | Channel IDs for allowlist policy |
| `dm.enabled` | No | `false` | Enable direct messages |
| `dm.policy` | No | `"allowlist"` | DM policy: `"allowlist"` or `"open"` |
| `dm.allow_from` | No | `[]` | User IDs for DM allowlist policy |

## Troubleshooting

Enable debug logging:

```sh
LOG_LEVEL=DEBUG autobot agent
```

**"Access denied for sender U..."** — the user ID is not in `allow_from`. Add it to the config.

**Bot connects but doesn't respond to mentions** — reinstall the app after adding event subscriptions. Go to **Install App** > **Reinstall to Workspace**.

**"Sending messages to this app has been turned off"** — enable the Messages Tab in **App Home** > **Show Tabs**.

**"Slack bot/app token not configured"** — tokens are empty. Check `.env` file and variable substitution.

**"Failed to open Slack connection"** — the app token is invalid or Socket Mode is not enabled. Check **Socket Mode** settings.
