# WhatsApp

Autobot connects to WhatsApp via a Node.js bridge that uses [@whiskeysockets/baileys](https://github.com/WhiskeySockets/Baileys) for the WhatsApp Web protocol. Communication between Autobot and the bridge is via JSON messages over WebSocket.

## Features

- **QR code authentication** — scan in the bridge terminal to connect
- **Reply context** — when replying to a message, the quoted text is included as context so the bot understands what you're referring to
- **Group chat support** — works in group conversations
- **Auto-reconnection** — reconnects automatically on disconnection
- **Access control** — allowlist-based sender filtering

## Configuration

Add a `whatsapp` block to the `channels` section of your `config.yml`:

```yaml
channels:
  whatsapp:
    enabled: true
    bridge_url: "ws://localhost:3001"
    # allow_from: []             - DENY ALL (secure default)
    # allow_from: ["*"]          - Allow anyone (use with caution)
    # allow_from: ["1234567890"] - Allowlist specific phone numbers
    allow_from: ["1234567890"]
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `enabled` | No | `false` | Enable the WhatsApp channel |
| `bridge_url` | No | `ws://localhost:3001` | WebSocket URL of the baileys bridge |
| `allow_from` | No | `[]` | Phone numbers allowed to use the bot, or `["*"]` for all |

## Setup

1. **Run the bridge** — start the Node.js baileys bridge (see bridge documentation)
2. **Scan QR code** — on first connection, scan the QR code shown in the bridge terminal with your WhatsApp mobile app
3. **Configure Autobot** — add the `bridge_url` and `allow_from` to your `config.yml`
4. **Start Autobot** — run `autobot gateway`

## Limitations

- Voice message transcription is not yet supported
- Image/media sending is not yet supported
- Requires a separate Node.js bridge process
