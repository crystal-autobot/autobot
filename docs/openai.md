# OpenAI

Autobot supports OpenAI as an LLM provider via the [Chat Completions API](https://platform.openai.com/docs/api-reference/chat). This gives access to the GPT-5 family, o3, and other OpenAI models. The mini and nano variants offer a great balance of capability and cost for everyday tasks.

## Setup

### 1. Get an API key

Create an API key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).

### 2. Configure credentials

Add your API key to the `.env` file:

```sh
OPENAI_API_KEY=sk-...
```

Or use the interactive setup:

```sh
autobot setup
# Select "OpenAI (GPT)" as provider
```

### 3. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "openai/gpt-5-mini"

providers:
  openai:
    api_key: "${OPENAI_API_KEY}"
```

### 4. Verify

```sh
autobot doctor
# Should show: ✓ LLM provider configured (openai)
```

## Model naming

Models use the `openai/` prefix followed by the OpenAI model ID:

```yaml
# GPT-5 family (recommended)
model: "openai/gpt-5-mini"       # Fast, cheap, capable (recommended default)
model: "openai/gpt-5-nano"       # Fastest, cheapest — great for simple tasks
model: "openai/gpt-5.2"          # Flagship — smartest, most precise

# Reasoning
model: "openai/o3"               # Complex reasoning tasks

# Coding
model: "openai/gpt-5.3-codex"   # Best for agentic coding

# Legacy (still available in the API)
model: "openai/gpt-4.1"
model: "openai/gpt-4.1-mini"
model: "openai/gpt-4.1-nano"
```

`gpt-5-mini` is a good default for most use cases — significantly cheaper and faster than the flagship while still handling tool use, coding, and reasoning well. Use `gpt-5-nano` for high-volume, simpler tasks like summarization or classification.

The `openai/` prefix tells autobot to route to the OpenAI API. It is stripped before sending to the API.

See the full model list in the [OpenAI docs](https://platform.openai.com/docs/models).

## Custom API base

To use a self-hosted proxy, Azure OpenAI, or any OpenAI-compatible endpoint:

```yaml
providers:
  openai:
    api_key: "${OPENAI_API_KEY}"
    api_base: "https://your-proxy.example.com/v1/chat/completions"
```

## Extra headers

Pass additional headers with every request:

```yaml
providers:
  openai:
    api_key: "${OPENAI_API_KEY}"
    extra_headers:
      X-Custom-Header: "value"
```

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes | — | OpenAI API key (`sk-...`) |
| `api_base` | No | `https://api.openai.com/v1/chat/completions` | Custom API endpoint |
| `extra_headers` | No | — | Additional HTTP headers for every request |

## How it works

OpenAI uses the standard Chat Completions API format, which is the baseline for most LLM providers:

- **`Authorization: Bearer` header** for authentication
- **Standard message format** with `role` and `content` fields
- **Function calling** via `tools` array with `tool_choice`

Autobot detects OpenAI models by keywords (`openai`, `gpt`, `o1`, `o3`, `o4`) and routes to the correct endpoint automatically. All GPT-5 family models, o3, and legacy GPT-4.1 models are supported. Tools, MCP servers, plugins, and all other features work seamlessly.

## Voice transcription

OpenAI provides the [Whisper API](https://platform.openai.com/docs/guides/speech-to-text) for voice transcription. When OpenAI is configured, voice messages are automatically transcribed using `whisper-1`. No extra configuration is needed — the API key is reused from the provider config.

If both Groq and OpenAI are configured, Groq is preferred for transcription (faster, free tier available).

## Known limitations

- **No streaming** — Responses are returned in full after the model finishes generating.
- **Tool choice is always `auto`** — There is no configuration to force a specific tool or disable tool use per-request.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `POST https://api.openai.com/v1/chat/completions model=...` — confirms provider is active
- `Response 200 (N bytes)` — confirms API response
- `HTTP 4xx/5xx: ...` — API errors with details

### Common issues

**"No LLM provider configured"** — Check that `api_key` is set and non-empty in `config.yml`.

**"API error: Incorrect API key provided"** — Invalid or revoked API key. Verify at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).

**"API error: Rate limit reached"** — Too many requests or tokens. Check your usage at [platform.openai.com/usage](https://platform.openai.com/usage).

**"API error: The model does not exist"** — Model ID is wrong, or you don't have access to the model. Check available models in your account.
