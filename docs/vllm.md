# vLLM / Local models

Autobot supports [vLLM](https://docs.vllm.ai/) and any OpenAI-compatible local inference server as an LLM provider. This lets you run models on your own hardware with full privacy and no API costs.

## Setup

### 1. Start a local server

Start a vLLM server (or any OpenAI-compatible endpoint):

```sh
# vLLM
vllm serve meta-llama/Llama-3.3-70B-Instruct --port 8000

# Ollama (OpenAI-compatible mode)
ollama serve  # Runs on port 11434

# llama.cpp server
llama-server -m model.gguf --port 8080
```

### 2. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "vllm/meta-llama/Llama-3.3-70B-Instruct"

providers:
  vllm:
    api_base: "http://localhost:8000"
    api_key: "token"
```

The `api_key` field is required by the config schema but most local servers ignore it. Use any non-empty value (e.g. `"token"` or `"none"`).

### 3. Verify

```sh
autobot doctor
# Should show: ✓ LLM provider configured (vllm)
```

## Model naming

For local providers, the model name after the `vllm/` prefix should match what the server expects:

```yaml
# vLLM — uses the model name from the serve command
model: "vllm/meta-llama/Llama-3.3-70B-Instruct"

# Ollama — uses the model tag
model: "vllm/llama3.3:70b"

# llama.cpp — usually any string works (model is already loaded)
model: "vllm/local"
```

## Endpoint configuration

The `api_base` should point to your server's base URL. Autobot appends `/chat/completions` automatically:

```yaml
# vLLM (default port 8000)
api_base: "http://localhost:8000"
# -> POST http://localhost:8000/chat/completions

# Ollama (default port 11434)
api_base: "http://localhost:11434/v1"
# -> POST http://localhost:11434/v1/chat/completions

# Custom server with full path
api_base: "http://localhost:8080/v1/chat/completions"
# -> POST http://localhost:8080/v1/chat/completions (used as-is)
```

If the `api_base` already ends with `/chat/completions`, it is used as-is.

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `api_key` | Yes* | — | API key or token (most local servers ignore it, use any non-empty value) |
| `api_base` | Yes | — | Server URL (e.g. `http://localhost:8000`) |
| `extra_headers` | No | — | Additional HTTP headers for every request |

*Required by config schema, but the value typically does not matter for local servers.

## How it works

vLLM and other local servers implement the OpenAI-compatible Chat Completions API:

- **`Authorization: Bearer` header** sent (most local servers ignore it)
- **Standard message format** with `role` and `content` fields
- **Function calling** works if the served model supports it

Autobot detects local providers by the `vllm` keyword or by explicit `provider_name` in config. The OpenAI-compatible request format is used for all local servers.

## Voice transcription

Local servers do not provide a transcription API. If you need voice message support, configure an additional [Groq](groq.md) or [OpenAI](openai.md) provider for Whisper-based transcription.

## Known limitations

- **No streaming** — Responses are returned in full after the model finishes generating.
- **Tool support varies** — Function calling depends on the model and server. Not all local models support tools.
- **Tool choice is always `auto`** — There is no configuration to force a specific tool or disable tool use per-request.
- **No automatic model detection** — You must specify the exact model name the server expects.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `POST http://localhost:8000/chat/completions model=...` — confirms provider is active
- `Response 200 (N bytes)` — confirms server response
- `LLM request failed: ...` — connection or request errors

### Common issues

**"No LLM provider configured"** — Check that `api_key` is set (any non-empty value) and `api_base` points to your running server.

**"LLM request failed: Connection refused"** — Server is not running or the port is wrong. Verify the server is up with `curl http://localhost:8000/v1/models`.

**"API error: model not found"** — The model name in config doesn't match what the server is serving. Check available models with `curl http://localhost:8000/v1/models`.

**Slow responses** — Local inference speed depends on your hardware (GPU/CPU). Smaller or quantized models run faster.
