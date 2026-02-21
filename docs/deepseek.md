# DeepSeek

Autobot supports DeepSeek as an LLM provider via its [OpenAI-compatible API](https://platform.deepseek.com/api-docs). This gives access to DeepSeek-V3, DeepSeek-R1, and other DeepSeek models known for strong reasoning and coding performance at competitive pricing.

## Setup

### 1. Get an API key

Create an API key at [platform.deepseek.com](https://platform.deepseek.com/).

### 2. Configure credentials

Add your API key to the `.env` file:

```sh
DEEPSEEK_API_KEY=...
```

Or use the interactive setup:

```sh
autobot setup
# Select "DeepSeek" as provider
```

### 3. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "deepseek/deepseek-chat"

providers:
  deepseek:
    api_key: "${DEEPSEEK_API_KEY}"
```

### 4. Verify

```sh
autobot doctor
# Should show: ✓ LLM provider configured (deepseek)
```

## Model naming

Models use the `deepseek/` prefix followed by the DeepSeek model ID:

```yaml
# General-purpose (DeepSeek-V3)
model: "deepseek/deepseek-chat"

# Reasoning (DeepSeek-R1)
model: "deepseek/deepseek-reasoner"
```

The `deepseek/` prefix tells autobot to route to the DeepSeek API. It is stripped before sending to the API.

## Reasoning content

DeepSeek-R1 (the `deepseek-reasoner` model) returns reasoning traces in its responses. Autobot captures these in the `reasoning_content` field, allowing downstream features to access the model's chain-of-thought.

## Custom API base

To use a proxy or alternative endpoint:

```yaml
providers:
  deepseek:
    api_key: "${DEEPSEEK_API_KEY}"
    api_base: "https://your-proxy.example.com/v1/chat/completions"
```

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes | — | DeepSeek API key |
| `api_base` | No | `https://api.deepseek.com/v1/chat/completions` | Custom API endpoint |
| `extra_headers` | No | — | Additional HTTP headers for every request |

## How it works

DeepSeek uses the OpenAI-compatible Chat Completions API format:

- **`Authorization: Bearer` header** for authentication
- **Standard message format** with `role` and `content` fields
- **`reasoning_content` field** returned for reasoning models (DeepSeek-R1)

Autobot detects DeepSeek models by the `deepseek` keyword and routes to the correct endpoint automatically. Tools, MCP servers, plugins, and all other features work the same as with other providers.

## Voice transcription

DeepSeek does not provide a transcription API. If you need voice message support, configure an additional [Groq](groq.md) or [OpenAI](openai.md) provider for Whisper-based transcription.

## Known limitations

- **No streaming** — Responses are returned in full after the model finishes generating.
- **Tool choice is always `auto`** — There is no configuration to force a specific tool or disable tool use per-request.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `POST https://api.deepseek.com/v1/chat/completions model=...` — confirms provider is active
- `Response 200 (N bytes)` — confirms API response
- `HTTP 4xx/5xx: ...` — API errors with details

### Common issues

**"No LLM provider configured"** — Check that `api_key` is set and non-empty in `config.yml`.

**"API error: authentication failed"** — Invalid or expired API key. Verify at [platform.deepseek.com](https://platform.deepseek.com/).

**"API error: rate limit exceeded"** — Too many requests. DeepSeek applies per-key rate limits based on your plan.
