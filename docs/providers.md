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
| [Kimi Code](kimi.md) | Direct | — | Optimized for coding tasks |
| [OpenRouter](openrouter.md) | Gateway | — | Hundreds of models, single API key |
| [AWS Bedrock](bedrock.md) | Cloud | — | Claude, Nova via AWS SigV4 auth |
| [DuckAI](duckai.md) | Free | — | Free models via duck.ai proxy (rate limited) |
| [vLLM / Local](vllm.md) | Local | — | Self-hosted, any OpenAI-compatible server |

**Direct** providers connect to the provider's own API. **Gateway** providers aggregate multiple upstream providers behind a single key. **Local** providers run on your own hardware.

## Quick comparison

**Best for getting started** — [Anthropic](anthropic.md) or [OpenAI](openai.md). Widely used, well-documented APIs.

**Best for speed** — [Groq](groq.md). Extremely fast inference with generous free tier.

**Best for cost** — [DeepSeek](deepseek.md). Strong models at low per-token pricing.

**Best for variety** — [OpenRouter](openrouter.md). Access hundreds of models with one API key.

**Best for enterprise** — [AWS Bedrock](bedrock.md). Runs in your AWS account with IAM-based access control.

**Best for free** — [DuckAI](duckai.md). Free access to multiple models via duck.ai (rate limited).

**Best for privacy** — [vLLM / Local](vllm.md). Data never leaves your machine.

## Model naming convention

All models use a `provider/model-id` format:

```yaml
model: "anthropic/claude-sonnet-4-5"
model: "openai/gpt-5-mini"
model: "deepseek/deepseek-chat"
model: "groq/llama-3.3-70b-versatile"
model: "gemini/gemini-2.5-flash"
model: "kimi/kimi-for-coding"
model: "openrouter/anthropic/claude-sonnet-4-5"
model: "bedrock/us.anthropic.claude-3-7-sonnet-20250219-v1:0"
model: "duckai/gpt-4o-mini"
model: "vllm/meta-llama/Llama-3.3-70B-Instruct"
```

The prefix tells autobot which provider to use. It is stripped before sending to the API (except for gateway providers like OpenRouter, where the model path is forwarded).

## Voice transcription

Voice messages are automatically transcribed when a supported provider is configured:

- **Groq** (preferred) — uses `whisper-large-v3-turbo`, faster with free tier
- **OpenAI** — uses `whisper-1`

If neither is configured, the bot replies that it could not hear the voice note instead of sending it to the model; see [Voice transcription](configuration.md#voice-transcription) for the per-bot settings. Transcription works regardless of which provider you use for chat — you can use DeepSeek for chat and Groq for voice transcription by configuring both.

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

## Prompt caching

Most providers can reuse work for a prompt that starts exactly like an earlier one, and they bill those cached tokens at a lower price. Autobot keeps the start of each request the same across turns and inside a tool loop, so the cache can be hit:

- The system prompt holds no clock. The current date and time (UTC) go at the end of the current user message, and the session stores that message exactly as it was sent, time line included. Each request of the next turn starts with the exact text of the previous turn's first request.
- With `memory_window: 0`, the session is trimmed in chunks: once it holds more than 20 messages, it drops to the last 10. The start of the history stays the same for several turns instead of moving on every turn.
- With `memory_window` above 0, each request carries at most the last 25 messages of the session, and that window moves forward 12 messages at a time instead of one per turn.
- Skills are listed in name order, and long-term memory comes after the skills. On providers that cache by prefix (OpenAI, DeepSeek), a memory update does not undo the cached skills. Anthropic and Gemini cache the system prompt as one block, so any change to it, memory included, writes that block again.
- Every step of a tool loop sends the same full tool list. A tool result longer than 20,000 characters is cut once, when it is added, and earlier tool results are never shortened or rewritten after that.

What autobot adds per provider:

- **OpenAI and OpenRouter** get a `prompt_cache_key` with a hash of the chat session, which helps send a chat's requests to the same cache. They get it only when the request goes to the provider's own host (`api.openai.com` or `openrouter.ai`), so self-hosted servers, Azure and proxies do not receive it. Other OpenAI-compatible providers do not get this field.
- **Anthropic** gets up to four cache marks: the system prompt, the tool list, the last history message before the current user message (so the conversation up to the previous turn is reused on the next turn), and the end of the request (so each step of a tool loop reuses the one before it).
- **Gemini** uses its own context cache, see [Gemini](gemini.md).
- Other providers cache on their own when they support it.

Each model call logs a `Tokens:` line with `cache_read` (tokens served from the cache) and `cache_create` (tokens written to the cache, when the provider reports them). Prompt tokens include cached tokens for every provider.

Because tool results stay whole for the rest of a turn, a long tool loop with many large results sends more tokens than a short one. On providers with caching, most of those tokens are billed at the cached rate.
