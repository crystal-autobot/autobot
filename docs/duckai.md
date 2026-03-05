# DuckAI (duck.ai)

Autobot supports [DuckDuckGo AI Chat](https://duck.ai/) as an LLM provider via the [DuckAI](https://github.com/amirkabiri/duckai) proxy. This gives access to multiple models for free, with no API key required.

## How it works

DuckDuckGo offers free AI chat at [duck.ai](https://duck.ai/). The API uses a custom authentication mechanism that requires a JavaScript runtime, so a lightweight proxy translates it into an OpenAI-compatible API.

The [DuckAI proxy](https://github.com/amirkabiri/duckai) runs locally and handles this translation. Autobot connects to it like any other OpenAI-compatible endpoint.

## Available models

| Model | Description |
|---|---|
| `gpt-4o-mini` | OpenAI GPT-4o Mini (default) |
| `claude-3-5-haiku-latest` | Anthropic Claude 3.5 Haiku |
| `meta-llama/Llama-4-Scout-17B-16E-Instruct` | Meta Llama 4 Scout |
| `mistralai/Mistral-Small-24B-Instruct-2501` | Mistral Small |

## Setup

### 1. Start the DuckAI proxy

Using Docker:

```sh
docker run -d -p 3000:3000 --name duckai docker.io/amirkabiri/duckai
```

Using Podman:

```sh
podman run -d -p 3000:3000 --name duckai docker.io/amirkabiri/duckai
```

Verify it's running:

```sh
curl http://localhost:3000/health
```

### 2. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "duckai/gpt-4o-mini"

providers:
  duckai:
    api_base: "http://localhost:3000/v1"
    api_key: "token"
```

The `api_key` field is required by the config schema but the DuckAI proxy ignores it. Use any non-empty value.

### 3. Verify

```sh
autobot doctor
# Should show: LLM provider configured (duckai)
```

## Model naming

Models use the `duckai/` prefix followed by the model ID:

```yaml
model: "duckai/gpt-4o-mini"
model: "duckai/claude-3-5-haiku-latest"
model: "duckai/meta-llama/Llama-4-Scout-17B-16E-Instruct"
model: "duckai/mistralai/Mistral-Small-24B-Instruct-2501"
```

The `duckai/` prefix tells autobot to route to the DuckAI proxy. It is stripped before sending to the API.

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes* | - | Any non-empty value (proxy ignores it) |
| `api_base` | Yes | - | DuckAI proxy URL (e.g. `http://localhost:3000/v1`) |
| `extra_headers` | No | - | Additional HTTP headers for every request |

*Required by config schema, but the value does not matter.

## Rate limits

DuckDuckGo enforces rate limits on the AI chat service:

- ~20 requests per 60-second window
- Minimum 1 second between requests
- The proxy handles backoff automatically

For heavy usage, consider using a paid provider instead.

## Known limitations

- **No streaming** - Responses are returned in full after the model finishes generating.
- **No tool/function calling** - DuckDuckGo's API does not support function calling. Tools like `exec`, `read_file`, etc. will not work.
- **Rate limited** - Free service with usage limits. Not suitable for production workloads.
- **Proxy required** - The DuckAI proxy must be running alongside autobot.
- **No voice transcription** - If you need voice message support, configure an additional [Groq](groq.md) or [OpenAI](openai.md) provider.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

### Common issues

**"No LLM provider configured"** - Check that `api_key` is set (any non-empty value) and `api_base` points to the running proxy.

**"LLM request failed: Connection refused"** - The DuckAI proxy is not running. Start it with `docker run -p 3000:3000 docker.io/amirkabiri/duckai`.

**"API error: DuckAI API error: 400 Bad Request"** - The model ID is not supported. Check the [available models](#available-models) list.

**"API error: 429 Too Many Requests"** - Rate limited. Wait a moment and try again. The proxy handles backoff automatically for subsequent requests.
