# Architecture

Autobot is organized around a message-driven agent loop.

## High-Level Flow

1. A channel (CLI/Telegram/Slack/WhatsApp) receives user input.
2. Message is routed through the internal bus.
3. Agent loop builds context (system prompt, memory, skills, history).
4. LLM response may request tool calls.
5. Tools execute and feed results back into the loop.
6. Final response is returned to the originating channel.

## Core Components

- `channels/*`: Channel adapters, message ingress/egress, and media download ([vision](vision.md))
- `agent/*`: Main loop, context assembly (including multimodal), subagent support, memory hooks
- `tools/*`: Built-in tool registry and tool implementations
- `mcp/*`: MCP client, proxy tools, and setup for external tool servers
- `plugins/*`: Plugin loader + lifecycle registry
- `cron/*`: Scheduler and job model
- `session/*`: JSONL-based session persistence
- `bus/*`: Internal pub/sub event bus
