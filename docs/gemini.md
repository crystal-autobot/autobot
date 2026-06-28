# Google Gemini

Autobot features native, highly optimized support for Google Gemini LLMs. It directly implements the `generateContent` and `cachedContents` REST APIs, offering native context caching to drastically reduce token usage and cost for long-running autonomous tasks.

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
    model: "gemini/gemini-3.5-flash"

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
# Gemini 3.5
model: "gemini/gemini-3.5-pro"
model: "gemini/gemini-3.5-flash"

# Gemini 2.5
model: "gemini/gemini-2.5-pro"
model: "gemini/gemini-2.5-flash"
```

The `gemini/` prefix tells autobot to route to the Gemini API. It is stripped before sending to the API.

See the full model list in the [Gemini docs](https://ai.google.dev/gemini-api/docs/models).

## Native Context Caching

Autobot automatically leverages Gemini's **Context Caching** API to optimize costs for long-running or looping agents.

If your agent's system prompt and tools payload exceeds **8,000 characters**, Autobot will:
1. Hash the system state.
2. Explicitly cache it on Google's servers for 1 hour (`ttl: "3600s"`).
3. Reuse that cache on subsequent loops or prompts.

This is highly recommended for autonomous agent execution as it routinely drops token costs by over 90%.

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes | — | Google AI API key |
| `api_base` | No | `https://generativelanguage.googleapis.com/v1beta` | Custom API endpoint |

## Troubleshooting

Enable debug logging to see request/response details and cache usage:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `Created explicit Gemini cache: ...` — confirms caching is working and saving tokens
- `HTTP 4xx/5xx: ...` — API errors with details

### Common issues

**"HTTP 400: Function call is missing a thought_signature"** — This indicates an outdated provider version that is failing to pass back Gemini's internal reasoning state. Update `autobot` to the latest version.

**"API error: API key not valid"** — Invalid or expired API key. Verify at [aistudio.google.com](https://aistudio.google.com/apikey).

**"API error: Resource has been exhausted"** — Rate limit or quota exceeded. Check your usage and limits in Google AI Studio.
