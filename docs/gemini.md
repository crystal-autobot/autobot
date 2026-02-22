# Google Gemini

Autobot supports Google Gemini as an LLM provider via the [OpenAI-compatible endpoint](https://ai.google.dev/gemini-api/docs/openai). This gives access to Gemini Pro, Flash, and other Google AI models.

## Setup

### 1. Get an API key

Create an API key at [aistudio.google.com](https://aistudio.google.com/apikey).

### 2. Configure credentials

Add your API key to the `.env` file:

```sh
GEMINI_API_KEY=...
```

Or use the interactive setup:

```sh
autobot setup
# Select "Google Gemini" as provider
```

### 3. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "gemini/gemini-2.5-flash"

providers:
  gemini:
    api_key: "${GEMINI_API_KEY}"
```

### 4. Verify

```sh
autobot doctor
# Should show: ✓ LLM provider configured (gemini)
```

## Model naming

Models use the `gemini/` prefix followed by the Google model ID:

```yaml
# Gemini 2.5
model: "gemini/gemini-2.5-pro"
model: "gemini/gemini-2.5-flash"

# Gemini 2.0
model: "gemini/gemini-2.0-flash"

# Gemini 1.5
model: "gemini/gemini-1.5-pro"
model: "gemini/gemini-1.5-flash"
```

The `gemini/` prefix tells autobot to route to the Gemini API. It is stripped before sending to the API.

See the full model list in the [Gemini docs](https://ai.google.dev/gemini-api/docs/models).

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes | — | Google AI API key |
| `api_base` | No | `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions` | Custom API endpoint |
| `extra_headers` | No | — | Additional HTTP headers for every request |

## How it works

Gemini uses Google's OpenAI-compatible endpoint, which follows the standard Chat Completions format:

- **`Authorization: Bearer` header** for authentication
- **Standard message format** with `role` and `content` fields
- **Function calling** via `tools` array

Autobot detects Gemini models by the `gemini` keyword and routes to Google's OpenAI-compatible endpoint automatically. Tools, MCP servers, plugins, and all other features work the same as with other providers.

Note that Gemini's error responses may use an array-wrapped format (`[{"error": {...}}]`). Autobot handles both standard and array-wrapped error formats transparently.

## Voice transcription

Gemini does not provide a Whisper-compatible transcription API. If you need voice message support, configure an additional [Groq](groq.md) or [OpenAI](openai.md) provider for Whisper-based transcription.

## Known limitations

- **No streaming** — Responses are returned in full after the model finishes generating.
- **Tool choice is always `auto`** — There is no configuration to force a specific tool or disable tool use per-request.
- **Free tier limits** — Google AI Studio has per-minute and per-day request limits on the free tier.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `POST https://generativelanguage.googleapis.com/... model=...` — confirms provider is active
- `Response 200 (N bytes)` — confirms API response
- `HTTP 4xx/5xx: ...` — API errors with details

### Common issues

**"No LLM provider configured"** — Check that `api_key` is set and non-empty in `config.yml`.

**"API error: API key not valid"** — Invalid or expired API key. Verify at [aistudio.google.com](https://aistudio.google.com/apikey).

**"API error: Resource has been exhausted"** — Rate limit or quota exceeded. Check your usage and limits in Google AI Studio.

**"API error: model not found"** — Model ID is wrong or not available. Check the [Gemini models page](https://ai.google.dev/gemini-api/docs/models) for current availability.
