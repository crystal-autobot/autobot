# Media support

Autobot handles media in three directions:

- **Vision (inbound)** — photos sent by users are downloaded, base64-encoded, and forwarded to the LLM as multimodal content blocks
- **Image generation (outbound)** — the LLM can create images via the `generate_image` tool and send them back to users
- **Voice transcription (inbound)** — voice messages are transcribed to text via the Whisper API before reaching the LLM

## Vision

### How it works

```
Channel (Telegram) -> Download & base64 encode -> Context builder -> LLM provider
```

1. **Channel** receives a photo and downloads the file bytes via the platform API
2. **MediaAttachment** stores the base64-encoded data in a transient `data` field (excluded from JSON serialization to avoid bloating session files)
3. **Context builder** detects attachments with `data` and builds an array of content blocks (text + image) in OpenAI's `image_url` format
4. **Provider** sends the content blocks directly for OpenAI-compatible APIs, or converts them to Anthropic's `image/source/base64` format for the native Anthropic path

### Supported channels

| Channel   | Status    | Notes                                    |
|-----------|-----------|------------------------------------------|
| Telegram  | Supported | Auto-downloads photos via Bot API        |
| Slack     | Planned   | Needs `url_private` download with auth   |
| WhatsApp  | Planned   | Needs bridge-side changes to forward images |
| Zulip     | Not supported | Media handling not yet implemented |

### Supported providers

All providers work with vision — the internal format uses OpenAI-compatible `image_url` content blocks:

- **OpenAI-compatible** (OpenAI, DeepSeek, Groq, Gemini, OpenRouter, vLLM, etc.) — content blocks are serialized directly, no conversion needed
- **Anthropic native** — `image_url` blocks are automatically converted to Anthropic's `image/source/base64` format

> **Note:** The LLM model itself must support vision. Non-vision models will ignore or fail to interpret image content.

### Configuration

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

### Limits

- **Max image size:** 20 MB (configurable via `MAX_IMAGE_SIZE` constant)
- **Telegram Bot API limit:** 20 MB for file downloads
- Images are **not persisted** in session history — only the current turn's images are sent to the LLM to avoid token cost bloat

### Architecture details

#### MediaAttachment.data

The `data` field on `MediaAttachment` uses `@[JSON::Field(ignore: true)]` to keep base64 image data out of JSON serialization. This means:

- Session files (JSONL) stay small — no multi-MB base64 strings
- Past images are not re-sent on subsequent turns
- The field is only populated for the current inbound message

#### Content block format

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

## Image generation

The `generate_image` tool allows the LLM to create images from text prompts and send them directly to users.

### How it works

```
User prompt -> LLM -> generate_image tool -> Provider API -> Channel -> User
```

1. The user asks the LLM to create an image
2. The LLM calls `generate_image(prompt)` with a description
3. The tool calls the provider's image generation API
4. Base64 image data is wrapped in an `OutboundMessage` with `MediaAttachment`
5. The channel sends the photo to the user (e.g. Telegram `sendPhoto`)

### Supported providers

| Provider | Default model | API |
|----------|--------------|-----|
| OpenAI | `gpt-image-1` | `/v1/images/generations` |
| Gemini | `gemini-2.5-flash-image` | `/v1beta/models/{model}:generateContent` |

> **Note:** Anthropic does not support image generation. When no explicit override is set, autobot automatically picks the first available image-capable provider (tries OpenAI, then Gemini). Use `tools.image.provider` to force a specific one.

### Configuration

Image generation is auto-enabled when an OpenAI or Gemini provider is configured. No extra settings needed.

To override the provider or model:

```yaml
tools:
  image:
    enabled: true
    provider: openai         # optional, auto-detected from configured providers
    model: gpt-image-1       # optional, auto-detected from provider
    size: 1024x1024          # optional, default: 1024x1024
```

### Supported channels (outbound)

| Channel   | Status    | Notes                                    |
|-----------|-----------|------------------------------------------|
| Telegram  | Supported | Sends photos via `sendPhoto` multipart API |
| Slack     | Text fallback | Logs warning, sends caption as text    |
| Zulip     | Text fallback | Logs warning, sends caption as text    |

---

## Voice transcription

Voice and audio messages received via Telegram are automatically transcribed to text using the Whisper API before being sent to the LLM.

### How it works

```
Telegram voice -> Download OGG -> Transcriber (Whisper API) -> Text in message content -> LLM
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

### Supported providers

| Provider | Model | API endpoint |
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
