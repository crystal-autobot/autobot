# OpenRouter

Autobot supports [OpenRouter](https://openrouter.ai/) as a gateway provider. OpenRouter aggregates hundreds of models from multiple providers (Anthropic, OpenAI, Google, Meta, Mistral, and more) behind a single API key and unified billing.

## Setup

### 1. Get an API key

Create an API key at [openrouter.ai/keys](https://openrouter.ai/keys).

### 2. Configure credentials

Add your API key to the `.env` file:

```sh
OPENROUTER_API_KEY=sk-or-...
```

Or use the interactive setup:

```sh
autobot setup
# Select "OpenRouter" as provider
```

### 3. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "openrouter/anthropic/claude-sonnet-4-5"

providers:
  openrouter:
    api_key: "${OPENROUTER_API_KEY}"
```

### 4. Verify

```sh
autobot doctor
# Should show: ✓ LLM provider configured (openrouter)
```

## Model naming

Models use the `openrouter/` prefix followed by the OpenRouter model path:

```yaml
# Anthropic via OpenRouter
model: "openrouter/anthropic/claude-sonnet-4-5"
model: "openrouter/anthropic/claude-3.5-haiku"

# OpenAI via OpenRouter
model: "openrouter/openai/gpt-4o"
model: "openrouter/openai/o3-mini"

# Google via OpenRouter
model: "openrouter/google/gemini-2.5-pro"

# Meta via OpenRouter
model: "openrouter/meta-llama/llama-3.3-70b-instruct"

# Auto-routing (picks the best model automatically)
model: "openrouter/auto"
```

The `openrouter/` prefix tells autobot to route through OpenRouter's API. OpenRouter model IDs include the original provider as part of the path (e.g. `anthropic/claude-sonnet-4-5`).

See the full model list at [openrouter.ai/models](https://openrouter.ai/models).

## Auto-detection

OpenRouter is auto-detected in two ways:

- **By API key prefix** — Keys starting with `sk-or-` are recognized as OpenRouter
- **By API base URL** — If `api_base` contains `openrouter`, the gateway is detected automatically

This means you can also use OpenRouter without explicit `openrouter/` model prefixes if the API key or base URL identifies it.

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes | — | OpenRouter API key (`sk-or-...`) |
| `api_base` | No | `https://openrouter.ai/api/v1/chat/completions` | Custom API endpoint |
| `extra_headers` | No | — | Additional HTTP headers for every request |

## How it works

OpenRouter acts as a gateway — it accepts OpenAI-compatible requests and forwards them to the upstream provider:

- **`Authorization: Bearer` header** for authentication
- **Standard OpenAI-compatible format** for all requests
- **Model prefix** — autobot automatically prepends `openrouter/` to model names for routing

Since OpenRouter forwards to the original provider, the underlying model's capabilities apply (tool use, context window, etc.). Autobot always uses the OpenAI-compatible path through OpenRouter, even for Anthropic models.

## Voice transcription

OpenRouter does not provide a transcription API. If you need voice message support, configure an additional [Groq](groq.md) or [OpenAI](openai.md) provider for Whisper-based transcription.

## Known limitations

- **No streaming** — Responses are returned in full after the model finishes generating.
- **No native Anthropic path** — Even when using Claude models through OpenRouter, autobot uses the OpenAI-compatible format (OpenRouter handles the conversion).
- **Tool choice is always `auto`** — There is no configuration to force a specific tool or disable tool use per-request.
- **Per-model limits vary** — Rate limits and pricing depend on the underlying model. Check [openrouter.ai/models](https://openrouter.ai/models) for details.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `POST https://openrouter.ai/api/v1/chat/completions model=...` — confirms gateway is active
- `Response 200 (N bytes)` — confirms API response
- `HTTP 4xx/5xx: ...` — API errors with details

### Common issues

**"No LLM provider configured"** — Check that `api_key` is set and non-empty in `config.yml`.

**"API error: invalid_api_key"** — Invalid or revoked API key. Verify at [openrouter.ai/keys](https://openrouter.ai/keys).

**"API error: insufficient_quota"** — Out of credits. Top up at [openrouter.ai/credits](https://openrouter.ai/credits).

**"API error: model_not_found"** — Model path is wrong or has been removed. Check the [OpenRouter models page](https://openrouter.ai/models) for current availability.
