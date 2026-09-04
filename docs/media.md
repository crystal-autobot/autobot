# Media support

Autobot handles media in three directions:

- **Vision (inbound)** — photos sent by users are downloaded, base64-encoded, and forwarded to the LLM as multimodal content blocks
- **Image generation (outbound)** — the LLM can create images via the `generate_image` tool and send them back to users
- **Voice transcription (inbound)** — voice notes are transcribed to text via the Whisper API before reaching the LLM

## Spoken is instruction, attached is content

Every incoming media message is classified before the agent sees it:

| What arrives | Treated as | Why |
|--------------|------------|-----|
| Typed text | instruction | The user's words |
| Voice note recorded in the chat by the sender | instruction | The user's words, spoken. Transcribed into the message text |
| Audio file, photo, document | content | Something handed over. Becomes an attachment |
| Anything forwarded, voice notes included | content | The words are not the sender's. Becomes an attachment |
| Typed text with media | text is the instruction, media is content | A caption or a message with a file |

Content never enters the message text. An audio file is transcribed when a
transcriber is available, but the transcript lives on the attachment
(`transcript`, `transcript_path`), not in `content`, so nothing inside a
recording can pass as an instruction from the user.

### The inbox

Incoming media files are saved under the workspace so agents and tools can
read them by path:

```yaml
media:
  inbox: inbox   # relative to the workspace, default
```

Each file gets a unique timestamped name and the extension of its MIME type.
Transcripts of content attachments are written next to the media file as
`.txt`. The directory is created with mode `0700` and files with `0600`.

### Attachment fields

`MediaAttachment` carries what the classification needs:

| Field | Meaning |
|-------|---------|
| `type` | `photo`, `voice`, `audio`, `document` |
| `origin` | `sender` or `forwarded` |
| `file_path` | Where the file was saved in the inbox |
| `transcript`, `transcript_path` | Transcript of a content attachment |
| `transcribed` | Whether a transcript was produced; false for a voice note nobody could hear |
| `duration_seconds`, `name`, `mime_type`, `size_bytes` | Metadata from the platform |

`sender_voice_note?` is true only for a voice note with origin `sender`; the channel treats such a note as spoken words unless typed text came with it.

### How attachments reach the model

The context builder appends every attachment to the user message as a
delimited block after the user's own words, and the system prompt states
that such blocks are material, not instructions:

```
Add to notes today's conversation with my car dealer

<attachment type="audio" origin="sender" name="New Recording 6.m4a" path="inbox/20260904-142723-ea7baff7.m4a" duration="134s">
...transcript...
</attachment>
```

Attribute values are escaped, a closing tag planted inside a transcript is
neutralized, and paths under the workspace are shown relative to it. A voice
note the sender recorded is not repeated in a block; its transcription is
already the message text. Photos keep their image block and get a label block
in front of it.

The rendered text, blocks included, is what the session history stores, so a
later turn can still answer questions about an earlier attachment. A transcript
longer than 4,000 characters is cut in the block with a pointer to the full
transcript file in the inbox, which the agent can read on demand.

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

### Verification

Run `autobot doctor` to check image generation status:

```
✓ Image generation available (openai)
```

Or if no provider is configured:

```
— Image generation (no openai/gemini provider)
```

---

## File sending

The `message` tool supports attaching files from the workspace via the `file_path` parameter. This allows the LLM to send generated files (images, GIFs, documents) back to users.

### How it works

```
LLM generates file (exec tool) -> message(content, file_path) -> Read & base64 encode -> Channel -> User
```

1. The LLM generates a file in the workspace (e.g. via `exec` running a Python script)
2. The LLM calls `message(content: "Here's your file", file_path: "output.gif")`
3. The tool reads the file from the workspace via the sandbox executor (base64-encoded)
4. The file is attached as a `MediaAttachment` on the `OutboundMessage`
5. The channel sends it using the appropriate API method

### Supported file types

| Extension | Media type | Telegram API method |
|-----------|-----------|---------------------|
| `.jpg`, `.jpeg`, `.png`, `.webp`, `.bmp` | photo | `sendPhoto` |
| `.gif` | animation | `sendAnimation` |
| `.mp4` | video | `sendDocument` |
| `.pdf` | document | `sendDocument` |
| `.ogg` | voice | `sendVoice` |
| `.mp3`, `.m4a`, `.wav`, `.webm` | audio | `sendAudio` |
| `.txt` | document | `sendDocument` |
| Other | document | `sendDocument` |

### Supported channels

| Channel   | Status    | Notes                                    |
|-----------|-----------|------------------------------------------|
| Telegram  | Supported | Photos, animations (GIFs), voice, audio, and documents |
| Slack     | Text fallback | Logs warning, sends caption as text    |
| Zulip     | Text fallback | Logs warning, sends caption as text    |

---

## Voice transcription

Voice notes and audio files received via Telegram are transcribed using the Whisper API. Where the text ends up depends on the classification above.

### How it works

```
Voice note from the sender -> Download -> Transcriber -> "[voice transcription]: ..." in message content -> LLM
Audio file or forwarded note -> Download -> Transcriber -> transcript on the attachment            -> LLM
```

1. **Channel** receives a voice note or audio file and downloads the file bytes
2. **Transcriber** sends the audio to the Whisper API (OpenAI or Groq) and receives text
3. For a voice note the sender recorded, with no typed text, the transcript becomes the message content as `[voice transcription]: {text}`
4. For an audio file, a forwarded voice note, or a voice note with typed text, the transcript is stored on the attachment and the message content only carries a label such as `[audio: title]`

### Configuration

Voice transcription is on by default and borrows the key of a Whisper-capable chat provider, Groq first, then OpenAI:

```yaml
providers:
  groq:
    api_key: "${GROQ_API_KEY}"  # Voice transcription enabled via Groq Whisper
```

The `transcription` section overrides that per bot:

```yaml
transcription:
  enabled: true                   # false turns transcription off for this bot
  provider: openai                # pin openai or groq instead of the groq-then-openai default
  api_key: "${TRANSCRIPTION_KEY}" # a key of its own, so audio never touches the chat provider's account
```

`api_key` without `provider` uses OpenAI. A pinned provider without any key leaves transcription unavailable, and `autobot doctor` says so.

When transcription is off or unavailable, a voice note the sender recorded is still saved to the inbox as an attachment without a transcript, but it is not sent to the model: the bot answers with a fixed reply that it could not hear the note and asks for typed text. Audio files and forwarded voice notes arrive as attachments without a transcript and the model is told so.

### Supported providers

| Provider | Model | API endpoint |
|----------|-------|-------------|
| Groq | `whisper-large-v3-turbo` | `api.groq.com/openai/v1/audio/transcriptions` |
| OpenAI | `whisper-1` | `api.openai.com/v1/audio/transcriptions` |

### Verification

Run `autobot doctor` to check voice transcription status:

```
✓ Voice transcription available (groq)
✓ Voice transcription available (openai, own key)
```

Or when it is off, or no provider is configured:

```
— Voice transcription disabled
— Voice transcription (no openai/groq provider)
! Voice transcription enabled but no api key for openai
```
