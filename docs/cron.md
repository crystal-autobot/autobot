# Cron & Scheduled Tasks

Autobot includes a built-in scheduler for recurring checks, one-time reminders, and deferred tasks. Jobs fire as full agent turns with access to all tools.

---

## Overview

The cron system solves three common needs:

- **Reminders** — "Remind me to drink water in 30 minutes" (one-time deferred task)
- **Recurring reports** — "Send me a weather summary every morning at 9am" (cron expression)
- **Periodic tasks** — "Check my email every 5 minutes" (fixed interval)

When a job fires, it triggers a full agent turn — the agent can use MCP tools, web search, memory, and any other registered tools to complete the task. The response is automatically delivered to the user.

---

## Schedule Types

### Fixed Interval (`every_seconds`)

Runs repeatedly at a fixed interval.

```
"Check my email every 5 minutes"
→ every_seconds: 300
```

### Cron Expression (`cron_expr`)

Standard 5-field cron syntax: `MIN(0-59) HOUR(0-23) DOM(1-31) MON(1-12) DOW(0-6)`

Supports: `*` (any), ranges (`9-17`), steps (`*/5`), lists (`1,15,30`), combos (`1-30/10`), named months (`jan`-`dec`), named days (`mon`-`sun`), and shortcuts (`@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`).

All values must be integers. Minimum granularity is 1 minute — for sub-minute intervals, use `every_seconds`.

```
"Send me a morning briefing at 9am"
→ cron_expr: "0 9 * * *"

"Every 5 minutes during work hours on weekdays"
→ cron_expr: "*/5 9-17 * * 1-5"
```

### One-Time (`at`)

Runs once at a specific time, then auto-deletes.

```
"Remind me at 3pm to call the dentist"
→ at: "2026-02-20T15:00:00Z"
```

---

## How It Works

### Job Execution Flow

```mermaid
graph LR
    TIMER[Timer fires] --> CHECK{Job due?}
    CHECK -->|yes| CALLBACK[on_job callback]
    CALLBACK --> BUS[Event Bus]
    BUS --> LOOP[Agent Loop]
    LOOP --> LLM[LLM + Tools]
    LLM --> USER[Response auto-delivered]

    style TIMER fill:#ab47bc,stroke:#8e24aa,color:#fff
    style BUS fill:#7c4dff,stroke:#651fff,color:#fff
    style LOOP fill:#5c6bc0,stroke:#3949ab,color:#fff
    style LLM fill:#26a69a,stroke:#00897b,color:#fff
    style USER fill:#ffa726,stroke:#fb8c00,color:#fff
```

1. **Timer fires** — The cron service detects a job is due
2. **Publish to bus** — An `InboundMessage` is published to the event bus with `channel: "system"` and `sender_id: "cron:{job_id}"`
3. **Agent turn** — The agent loop picks up the message and executes the job's prompt
4. **Tool execution** — The agent uses any tools needed (MCP, web search, etc.) to fulfill the task
5. **Explicit delivery** — The agent uses the `message` tool to send results to the user (no auto-delivery)

### Background Turn Restrictions

Cron turns use a minimal system prompt and exclude certain tools to prevent unintended behavior:

- **`spawn`** — excluded to prevent background task proliferation

Cron turns never auto-deliver the final response. The agent must use the `message` tool explicitly to notify the user. This enables **conditional delivery** — the agent can stay silent when there is nothing to report (e.g., "monitor X, only notify if Y changes").

The `cron` tool is available so jobs can self-remove when their task defines a stop condition (e.g., "monitor X until condition Y, then stop").

---

## Configuration

### Enable Cron

```yaml
cron:
  enabled: true
  store_path: "./cron.json"  # Optional, defaults to workspace
```

### Agent Creates Jobs

The agent creates cron jobs via the `cron` tool when users make scheduling requests. The tool supports three actions:

| Action | Description | Required Parameters |
|--------|-------------|---------------------|
| `add` | Create a new job | `message` + one of: `every_seconds`, `cron_expr`, `at` |
| `list` | List jobs for current owner | — |
| `show` | Show full job details | `job_id` |
| `update` | Update schedule or message in-place | `job_id` + at least one of: `message`, `every_seconds`, `cron_expr`, `at` |
| `remove` | Delete a job | `job_id` |

---

## Telegram `/cron` Command

Send `/cron` in Telegram to instantly see all your scheduled jobs — no LLM round-trip needed.

**Example output:**

```
Scheduled jobs (2)

1. abc123 — Check GitHub stars
   ⏱ Every 10 min | ✅ 2 min ago

2. def456 — Morning briefing
   🕐 0 9 * * 1-5 (UTC) | ⏳ pending
```

Empty state shows: "No scheduled jobs. Ask me in chat to schedule something."

---

## Built-in Cron Skill

A built-in skill (`src/skills/cron/SKILL.md`) is available for the agent to load on demand. It teaches the agent:

- **Message quality** — write self-contained prompts with specific tool names and URLs
- **Timezone handling** — ask the user, convert to UTC, confirm both times
- **Update-first rule** — list existing jobs before creating, update instead of duplicate
- **Schedule type selection** — when to use `every_seconds` vs `cron_expr` vs `at`

The agent loads this skill when handling scheduling requests, keeping non-cron prompts lightweight.

---

## CLI Management

### List Jobs

```bash
autobot cron list        # Show enabled jobs
autobot cron list --all  # Include disabled jobs
```

### Show Job Details

```bash
autobot cron show <job_id>
```

### Add Jobs Manually

```bash
# Recurring interval
autobot cron add --name "standup" --message "Time for standup!" --every 3600

# Cron expression
autobot cron add --name "morning" --message "Good morning!" --cron "0 9 * * *"

# One-time
autobot cron add --name "reminder" --message "Call dentist" --at "2026-02-20T15:00:00Z"
```

### Update a Job

```bash
# Change schedule
autobot cron update <job_id> --cron "0 8 * * *"

# Change message
autobot cron update <job_id> --message "New task instructions"

# Change both
autobot cron update <job_id> --every 600 --message "Updated check"
```

### Remove a Job

```bash
autobot cron remove <job_id>
```

### Clear All Jobs

```bash
autobot cron clear
```

### Enable/Disable

```bash
autobot cron enable <job_id>
autobot cron disable <job_id>
```

### Force Run

```bash
autobot cron run <job_id>          # Run if enabled
autobot cron run <job_id> --force  # Run even if disabled
```

---

## Per-Owner Isolation

Jobs created via the `cron` tool are automatically scoped to the originating channel and chat. A Telegram user's jobs are isolated from a Slack user's jobs.

- **Owner format:** `channel:chat_id` (e.g., `telegram:634643933`)
- **List** only shows the current owner's jobs
- **Update** only works on the current owner's jobs
- **Remove** only works on the current owner's jobs
- Jobs created via CLI have no owner restriction

---

## Examples

### One-Time Reminder

User says: *"Remind me in 30 minutes to take a break"*

The agent creates:
```
cron add:
  message: "Send the user a reminder to take a break."
  at: "2026-02-20T10:30:00Z"
```

Job fires once, delivers the reminder, then auto-deletes.

### Daily Report

User says: *"Send me a weather summary every morning at 9am"*

The agent creates:
```
cron add:
  message: "Use web_search to find current weather for user's location.
            Send a brief summary."
  cron_expr: "0 9 * * *"
```

### Periodic Check

User says: *"Check my email every 5 minutes"*

The agent creates:
```
cron add:
  message: "Check email and notify the user of new messages."
  every_seconds: 300
```

### Update Existing Job

User says: *"Change my morning report to 8am instead"*

The agent updates:
```
cron update:
  job_id: "a1b2c3d4"
  cron_expr: "0 8 * * *"
```

Job identity (`id`, `created_at_ms`, `state`) is preserved — only the schedule changes.

---

## File Structure

```
workspace/
└── cron.json    # Job definitions (auto-created)
```

**Permissions:**

- `cron.json`: `0600` (user read/write only)
- Parent directory: `0700` (user-only access)

---

## Troubleshooting

### Job doesn't fire

**Check:**

1. Is cron enabled in config? (`cron.enabled: true`)
2. Is the job enabled? (`autobot cron show <job_id>`)
3. Is the gateway running? (Jobs only fire while the gateway process is active)
4. Check logs for `Cron: executing job` entries

---

## See Also

- [Architecture](architecture.md) — System design and message flow
- [Configuration](configuration.md) — Full config reference
- [Security](security.md) — File permissions and job isolation
