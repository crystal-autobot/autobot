# Providers

Autobot supports multiple LLM providers out of the box. Configure at least one provider to get started.

## Supported providers

| Provider | Type | Voice transcription | Notes |
|---|---|---|---|
| [Anthropic](anthropic.md) | Direct | — | Claude models via native Messages API |
| [OpenAI](openai.md) | Direct | Whisper | GPT-5 family, o3 models |
| [DeepSeek](deepseek.md) | Direct | — | DeepSeek-V3, R1 with reasoning traces |
| [Groq](groq.md) | Direct | Whisper (preferred) | Ultra-fast inference on LPU hardware |
| [Google Gemini](gemini.md) | Direct | — | Gemini Pro, Flash models |
| [OpenRouter](openrouter.md) | Gateway | — | Hundreds of models, single API key |
| [AWS Bedrock](bedrock.md) | Cloud | — | Claude, Nova via AWS SigV4 auth |
| [vLLM / Local](vllm.md) | Local | — | Self-hosted, any OpenAI-compatible server |

**Direct** providers connect to the provider's own API. **Gateway** providers aggregate multiple upstream providers behind a single key. **Local** providers run on your own hardware.

## Quick comparison

**Best for getting started** — [Anthropic](anthropic.md) or [OpenAI](openai.md). Widely used, well-documented APIs.

**Best for speed** — [Groq](groq.md). Extremely fast inference with generous free tier.

**Best for cost** — [DeepSeek](deepseek.md). Strong models at low per-token pricing.

**Best for variety** — [OpenRouter](openrouter.md). Access hundreds of models with one API key.

**Best for enterprise** — [AWS Bedrock](bedrock.md). Runs in your AWS account with IAM-based access control.

**Best for privacy** — [vLLM / Local](vllm.md). Data never leaves your machine.

## Model naming convention

All models use a `provider/model-id` format:

```yaml
model: "anthropic/claude-sonnet-4-5"
model: "openai/gpt-5-mini"
model: "deepseek/deepseek-chat"
model: "groq/llama-3.3-70b-versatile"
model: "gemini/gemini-2.5-flash"
model: "openrouter/anthropic/claude-sonnet-4-5"
model: "bedrock/us.anthropic.claude-3-7-sonnet-20250219-v1:0"
model: "vllm/meta-llama/Llama-3.3-70B-Instruct"
```

The prefix tells autobot which provider to use. It is stripped before sending to the API (except for gateway providers like OpenRouter, where the model path is forwarded).

## Voice transcription

Voice messages are automatically transcribed when a supported provider is configured:

- **Groq** (preferred) — uses `whisper-large-v3-turbo`, faster with free tier
- **OpenAI** — uses `whisper-1`

If neither is configured, voice messages fall back to `[voice message]` text. Transcription works regardless of which provider you use for chat — you can use DeepSeek for chat and Groq for voice transcription by configuring both.

## Multiple providers

You can configure multiple providers simultaneously. Autobot selects the provider based on the model prefix in your config:

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
  groq:
    api_key: "${GROQ_API_KEY}"

agents:
  defaults:
    model: "anthropic/claude-sonnet-4-5"  # Uses Anthropic for chat
                                           # Uses Groq for voice transcription
```

## Feature compatibility

All providers support the same autobot features:

- Tool use and function calling
- MCP servers
- Plugins
- Memory system
- Cron scheduling
- All chat channels (Telegram, Slack, WhatsApp, Zulip, CLI)

The only exception is voice transcription, which requires Groq or OpenAI (see above).
