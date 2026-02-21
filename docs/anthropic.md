# Anthropic

Autobot supports Anthropic as an LLM provider via the [Messages API](https://docs.anthropic.com/en/api/messages). This gives access to the Claude model family including Claude Opus, Sonnet, and Haiku.

## Setup

### 1. Get an API key

Create an API key at [console.anthropic.com](https://console.anthropic.com/).

### 2. Configure credentials

Add your API key to the `.env` file:

```sh
ANTHROPIC_API_KEY=sk-ant-...
```

Or use the interactive setup:

```sh
autobot setup
# Select "Anthropic (Claude)" as provider
```

### 3. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "anthropic/claude-haiku-4-5"

providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
```

### 4. Verify

```sh
autobot doctor
# Should show: ✓ LLM provider configured (anthropic)
```

## Model naming

Models use the `anthropic/` prefix followed by the Anthropic model ID:

```yaml
# Latest (recommended)
model: "anthropic/claude-haiku-4-5"     # Fast, cheap, capable (recommended default)
model: "anthropic/claude-sonnet-4-6"    # Mid-tier — strong coding and reasoning
model: "anthropic/claude-opus-4-6"      # Flagship — smartest, 1M context

# Previous generation (still available)
model: "anthropic/claude-sonnet-4-5"
model: "anthropic/claude-opus-4-5"
model: "anthropic/claude-sonnet-4"
model: "anthropic/claude-opus-4"
```

`claude-haiku-4-5` is a good default for most use cases — fast, affordable ($1/$5 per 1M tokens), and capable enough for tool use, coding, and everyday tasks. Use Sonnet or Opus when you need stronger reasoning or larger context.

The `anthropic/` prefix tells autobot to route to the Anthropic Messages API. It is stripped before sending to the API.

See the full model list in the [Anthropic docs](https://docs.anthropic.com/en/docs/about-claude/models).

## Custom API base

To use a self-hosted proxy or alternative endpoint:

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
    api_base: "https://your-proxy.example.com/v1/messages"
```

## Extra headers

Pass additional headers with every request (e.g. for proxy authentication):

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
    extra_headers:
      X-Custom-Header: "value"
```

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes | — | Anthropic API key (`sk-ant-...`) |
| `api_base` | No | `https://api.anthropic.com/v1/messages` | Custom API endpoint |
| `extra_headers` | No | — | Additional HTTP headers for every request |

## How it works

Anthropic uses its own Messages API format, which differs from the OpenAI-compatible standard:

- **`x-api-key` header** for authentication (not `Authorization: Bearer`)
- **`anthropic-version` header** sent with every request (`2023-06-01`)
- **System prompt** extracted from messages and sent as a top-level `system` field
- **Tool use** blocks use `tool_use` / `tool_result` format instead of `function`

Autobot detects Anthropic models automatically and handles all format conversion transparently. Tools, MCP servers, plugins, and all other features work the same as with other providers.

## Voice transcription

Anthropic does not provide a transcription API. If you need voice message support, configure an additional [Groq](groq.md) or [OpenAI](openai.md) provider for Whisper-based transcription.

## Known limitations

- **No streaming** — Responses are returned in full after the model finishes generating.
- **Text and image content only** — Document and audio content blocks are not supported.
- **Tool choice is always `auto`** — There is no configuration to force a specific tool or disable tool use per-request.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `POST https://api.anthropic.com/v1/messages model=... (anthropic)` — confirms native Anthropic path
- `Response 200 (N bytes)` — confirms API response
- `HTTP 4xx/5xx: ...` — API errors with details

### Common issues

**"No LLM provider configured"** — Check that `api_key` is set and non-empty in `config.yml`.

**"API error: authentication_error"** — Invalid or expired API key. Verify at [console.anthropic.com](https://console.anthropic.com/).

**"API error: rate_limit_error"** — Too many requests. Anthropic applies per-key rate limits — check your plan's limits.

**"API error: overloaded_error"** — The API is temporarily overloaded. Retry after a moment.
