# Kimi Code

Autobot supports Kimi Code (by Moonshot AI) as an LLM provider. Kimi Code is highly optimized for coding tasks and agentic workflows.

## Setup

### 1. Get an API key

Create an API key on the [Kimi Code membership page](https://www.kimi.com/code/).

### 2. Configure credentials

Add your API key to the `.env` file:

```sh
KIMI_API_KEY=sk-kimi-...
```

Or use the interactive setup:

```sh
autobot setup
# Select "Kimi Code" as provider
```

### 3. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "kimi/kimi-for-coding"

providers:
  kimi:
    api_key: "${KIMI_API_KEY}"
```

### 4. Verify

```sh
autobot doctor
# Should show: ✓ LLM provider configured (kimi)
```

## Model naming

Models use the `kimi/` prefix followed by the Kimi model ID:

```yaml
model: "kimi/kimi-for-coding"   # Optimized for coding tasks (recommended)
```

The `kimi/` prefix tells autobot to route to the Kimi Code API. It is stripped before sending to the API.

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes | — | Kimi API key (`sk-kimi-...`) |
| `api_base` | No | `https://api.kimi.com/coding/v1/chat/completions` | Custom API endpoint |
| `extra_headers` | No | — | Additional HTTP headers for every request |

## How it works

Kimi Code uses an OpenAI-compatible Chat Completions API. Autobot detects Kimi models by the `kimi/` prefix or keywords and routes to the coding-optimized endpoint automatically.

- **Context Window:** 262,144 tokens
- **Max Output:** 32,768 tokens
- **Optimization:** Highly tuned for tool use and long-context coding tasks.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `POST https://api.kimi.com/coding/v1/chat/completions model=...` — confirms provider is active
- `Response 200 (N bytes)` — confirms API response
- `HTTP 4xx/5xx: ...` — API errors with details

### Common issues

**"API error: Rate limit reached"** — Too many requests or tokens. Check your Kimi account status.

**"API error: The model does not exist"** — Model ID is wrong. Ensure you are using `kimi-for-coding`.
