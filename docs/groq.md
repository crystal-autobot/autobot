# Groq

Autobot supports Groq as an LLM provider via its [OpenAI-compatible API](https://console.groq.com/docs/api-reference). Groq is known for ultra-fast inference powered by custom LPU hardware, offering models like Llama, Mixtral, and Gemma with extremely low latency.

## Setup

### 1. Get an API key

Create an API key at [console.groq.com](https://console.groq.com/).

### 2. Configure credentials

Add your API key to the `.env` file:

```sh
GROQ_API_KEY=gsk_...
```

Or use the interactive setup:

```sh
autobot setup
# Select "Groq" as provider
```

### 3. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "groq/llama-3.3-70b-versatile"

providers:
  groq:
    api_key: "${GROQ_API_KEY}"
```

### 4. Verify

```sh
autobot doctor
# Should show: ✓ LLM provider configured (groq)
```

## Model naming

Models use the `groq/` prefix followed by the Groq model ID:

```yaml
# Llama models
model: "groq/llama-3.3-70b-versatile"
model: "groq/llama-3.1-8b-instant"

# Mixtral
model: "groq/mixtral-8x7b-32768"

# Gemma
model: "groq/gemma2-9b-it"
```

The `groq/` prefix tells autobot to route to the Groq API. It is stripped before sending to the API.

See the full model list in the [Groq docs](https://console.groq.com/docs/models).

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes | — | Groq API key (`gsk_...`) |
| `api_base` | No | `https://api.groq.com/openai/v1/chat/completions` | Custom API endpoint |
| `extra_headers` | No | — | Additional HTTP headers for every request |

## How it works

Groq uses the OpenAI-compatible Chat Completions API format:

- **`Authorization: Bearer` header** for authentication
- **Standard message format** with `role` and `content` fields
- **Function calling** via `tools` array

Autobot detects Groq models by the `groq` keyword and routes to the correct endpoint automatically. Tools, MCP servers, plugins, and all other features work the same as with other providers.

## Voice transcription

Groq provides the [Whisper API](https://console.groq.com/docs/speech-text) for voice transcription. When Groq is configured, voice messages are automatically transcribed using `whisper-large-v3-turbo`. No extra configuration is needed — the API key is reused from the provider config.

Groq is the **preferred transcription provider** when available (faster than OpenAI, free tier included). If both Groq and OpenAI are configured, Groq takes priority for transcription.

## Known limitations

- **No streaming** — Responses are returned in full after the model finishes generating.
- **Tool choice is always `auto`** — There is no configuration to force a specific tool or disable tool use per-request.
- **Rate limits** — Groq's free tier has token and request limits. Check [console.groq.com](https://console.groq.com/) for current limits.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `POST https://api.groq.com/openai/v1/chat/completions model=...` — confirms provider is active
- `Response 200 (N bytes)` — confirms API response
- `HTTP 4xx/5xx: ...` — API errors with details

### Common issues

**"No LLM provider configured"** — Check that `api_key` is set and non-empty in `config.yml`.

**"API error: Invalid API Key"** — Invalid or revoked API key. Verify at [console.groq.com](https://console.groq.com/).

**"API error: Rate limit reached"** — Too many requests or tokens per minute. Groq's free tier has lower limits — consider upgrading or spacing out requests.

**"API error: model_not_found"** — Model ID is wrong or has been deprecated. Check the [Groq models page](https://console.groq.com/docs/models) for current availability.
