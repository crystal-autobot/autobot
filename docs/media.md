# Media Support

Autobot supports image analysis by downloading images from chat channels, encoding them as base64, and sending them to the LLM as multimodal content blocks.

Autobot also supports voice transcription — voice messages are automatically transcribed to text using Whisper API and included in the LLM context.

## How It Works

```
Channel (Telegram) -> Download & Base64 encode -> Context Builder -> LLM Provider
```

1. **Channel** receives a photo and downloads the file bytes via the platform API
2. **MediaAttachment** stores the base64-encoded data in a transient `data` field (excluded from JSON serialization to avoid bloating session files)
3. **Context Builder** detects attachments with `data` and builds an array of content blocks (text + image) in OpenAI's `image_url` format
4. **Provider** sends the content blocks directly for OpenAI-compatible APIs, or converts them to Anthropic's `image/source/base64` format for the native Anthropic path

## Supported Channels

| Channel   | Status    | Notes                                    |
|-----------|-----------|------------------------------------------|
| Telegram  | Supported | Auto-downloads photos via Bot API        |
| Slack     | Planned   | Needs `url_private` download with auth   |
| WhatsApp  | Planned   | Needs bridge-side changes to forward images |

## Supported Providers

All providers work with vision — the internal format uses OpenAI-compatible `image_url` content blocks:

- **OpenAI-compatible** (OpenAI, DeepSeek, Groq, Gemini, OpenRouter, vLLM, etc.) — content blocks are serialized directly, no conversion needed
- **Anthropic native** — `image_url` blocks are automatically converted to Anthropic's `image/source/base64` format

> **Note:** The LLM model itself must support vision. Non-vision models will ignore or fail to interpret image content.

## Configuration

No additional configuration is needed. Vision works automatically when:

- The channel is enabled and configured
- The LLM model supports multimodal/vision input

Optional proxy support for Telegram file downloads:

```yaml
channels:
  telegram:
    enabled: true
    token: "BOT_TOKEN"
    proxy: "http://proxy.example.com:8080"  # Optional
```

## Limits

- **Max image size:** 20 MB (configurable via `MAX_IMAGE_SIZE` constant)
- **Telegram Bot API limit:** 20 MB for file downloads
- Images are **not persisted** in session history — only the current turn's images are sent to the LLM to avoid token cost bloat

## Architecture Details

### MediaAttachment.data

The `data` field on `MediaAttachment` uses `@[JSON::Field(ignore: true)]` to keep base64 image data out of JSON serialization. This means:

- Session files (JSONL) stay small — no multi-MB base64 strings
- Past images are not re-sent on subsequent turns
- The field is only populated for the current inbound message

### Content Block Format

The context builder produces OpenAI-format content blocks:

```json
[
  {"type": "text", "text": "Analyze this image"},
  {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
]
```

For Anthropic native, this is converted to:

```json
[
  {"type": "text", "text": "Analyze this image"},
  {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "..."}}
]
```

---

## Voice Transcription

Voice and audio messages received via Telegram are automatically transcribed to text using the Whisper API before being sent to the LLM.

### How It Works

```
Telegram voice -> Download OGG -> Transcriber (Whisper API) -> text in message content -> LLM
```

1. **Channel** receives a voice/audio message and downloads the file bytes
2. **Transcriber** sends the audio to the Whisper API (OpenAI or Groq) and receives text
3. The transcribed text replaces the `[voice message]` placeholder as `[voice transcription]: {text}`
4. The LLM receives the transcription as regular text content

### Configuration

No extra configuration needed. Voice transcription is auto-enabled when a Whisper-capable provider (Groq or OpenAI) is configured:

```yaml
providers:
  groq:
    api_key: "${GROQ_API_KEY}"  # Voice transcription auto-enabled via Groq Whisper
```

Or:

```yaml
providers:
  openai:
    api_key: "${OPENAI_API_KEY}"  # Voice transcription auto-enabled via OpenAI Whisper
```

Groq is preferred when both are configured (faster, has free tier). If neither is configured, voice messages fall back to `[voice message]` text with no errors.

### Supported Providers

| Provider | Model | API Endpoint |
|----------|-------|-------------|
| Groq | `whisper-large-v3-turbo` | `api.groq.com/openai/v1/audio/transcriptions` |
| OpenAI | `whisper-1` | `api.openai.com/v1/audio/transcriptions` |

### Verification

Run `autobot doctor` to check voice transcription status:

```
✓ Voice transcription available (groq)
```

Or if no provider is configured:

```
— Voice transcription (no openai/groq provider)
```
