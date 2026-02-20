# AWS Bedrock

Autobot supports AWS Bedrock as an LLM provider via the [Converse API](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html). This gives access to Claude, Amazon Nova, and other foundation models hosted on AWS with SigV4 authentication.

## Setup

### 1. Configure credentials

Add AWS credentials to your `.env` file:

```sh
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=wJalr...
AWS_REGION=us-east-1
```

Or use the interactive setup:

```sh
autobot setup
# Select "AWS Bedrock" as provider
```

### 2. Configure the provider

In `config.yml`:

```yaml
agents:
  defaults:
    model: "bedrock/us.anthropic.claude-3-7-sonnet-20250219-v1:0"

providers:
  bedrock:
    access_key_id: "${AWS_ACCESS_KEY_ID}"
    secret_access_key: "${AWS_SECRET_ACCESS_KEY}"
    region: "${AWS_REGION}"
```

### 3. Verify

```sh
autobot doctor
# Should show: ✓ LLM provider configured (bedrock)
```

## Model naming

Models must use the `bedrock/` prefix. After the prefix, use the Bedrock model ID:

```yaml
# Foundation models
model: "bedrock/anthropic.claude-3-5-sonnet-20241022-v2:0"
model: "bedrock/amazon.nova-pro-v1:0"

# Cross-region inference profiles
model: "bedrock/us.anthropic.claude-3-7-sonnet-20250219-v1:0"
```

The `bedrock/` prefix tells autobot to route to the Bedrock provider instead of the HTTP provider. It is stripped before sending to the API.

## Guardrails

Bedrock [Guardrails](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails.html) can filter harmful content. Both `guardrail_id` and `guardrail_version` are required — setting only `guardrail_id` logs a warning and disables guardrails.

```yaml
providers:
  bedrock:
    access_key_id: "${AWS_ACCESS_KEY_ID}"
    secret_access_key: "${AWS_SECRET_ACCESS_KEY}"
    region: "${AWS_REGION}"
    guardrail_id: "abc123def456"
    guardrail_version: "1"
```

When a guardrail intervenes, the response includes `finish_reason: "guardrail_intervened"` and the guardrail trace is logged at INFO level.

## Session tokens

For temporary credentials (e.g. from `aws sts assume-role`), add `session_token`:

```yaml
providers:
  bedrock:
    access_key_id: "${AWS_ACCESS_KEY_ID}"
    secret_access_key: "${AWS_SECRET_ACCESS_KEY}"
    session_token: "${AWS_SESSION_TOKEN}"
    region: "${AWS_REGION}"
```

## Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `access_key_id` | Yes | — | AWS access key ID |
| `secret_access_key` | Yes | — | AWS secret access key |
| `region` | No | `us-east-1` | AWS region |
| `session_token` | No | — | Temporary session token (STS) |
| `guardrail_id` | No | — | Bedrock guardrail identifier |
| `guardrail_version` | No | — | Guardrail version (required if guardrail_id is set) |

## How it works

Unlike other providers that use OpenAI-compatible HTTP APIs, Bedrock uses:

- **AWS SigV4** authentication (no API keys)
- **Converse API** endpoint (`/model/{modelId}/converse`)
- **Union-key content blocks** (`{"text": "..."}` instead of `{"type": "text", ...}`)
- **camelCase** field names (`toolUse`, `toolResult`, `inputSchema`)

Autobot handles all format conversion transparently. Tools, MCP servers, plugins, and all other features work the same as with other providers.

## Known limitations

- **No streaming** — Responses are returned in full after the model finishes generating. The `ConverseStream` API is not used.
- **No credential refresh** — SigV4 credentials are set at startup. Temporary credentials (STS session tokens) will not refresh when they expire; restart autobot to pick up new credentials.
- **Text-only content blocks** — Image and document content blocks in messages and tool results are not converted. Only text is sent to Bedrock.
- **Tool choice is always `auto`** — There is no configuration to force a specific tool or disable tool use per-request.

## Troubleshooting

Enable debug logging to see request/response details:

```sh
LOG_LEVEL=DEBUG autobot agent -m "Hello"
```

Look for:

- `Bedrock: region=... model=...` — confirms provider is active
- `Bedrock toolConfig: N tools` — confirms tools are in the request
- `Response 200 (N bytes)` — confirms API response
- `HTTP 4xx/5xx: ...` — API errors with details

### Common issues

**"No LLM provider configured"** — Model must start with `bedrock/` prefix.

**"HTTP 403: ..."** — Check IAM permissions. The role needs `bedrock:InvokeModel` on the model ARN.

**"HTTP 404: ..."** — Model not available in the configured region. Try a cross-region inference profile (e.g. `us.anthropic.claude-...`).

**guardrail_id without guardrail_version** — Both are required. Check logs for the warning message.
