---
name: cron
description: Scheduling rules for reminders and recurring tasks.
tool: cron
---

## Cron scheduling rules

### Job naming

Always provide a short `name` for every job (max 30 chars). This label is shown in `/cron` and `list` output.
Keep it human-readable — describe what the job does, not how.

Bad: "Use the web_search tool to che"
Good: "GitHub stars check"

### Message quality

The `message` field is the prompt for a background agent turn that runs without conversation context.
Write it as a self-contained instruction:

- Include the specific action, tool name, URLs, thresholds, and any values the user mentioned
- 50+ words for complex tasks; short reminders can be brief
- Never use pronouns ("check it", "do the thing") — be explicit

Bad: "Check the repo"
Good: "Use the web_search tool to check https://github.com/user/repo for new releases published in the last 24 hours. If there is a new release, summarize the changelog."

### Timezone handling

1. If the user mentions a timezone or city, convert to UTC and confirm both times
2. If unclear, ask which timezone they mean before scheduling
3. Always store and display schedules in UTC
4. Confirm: "Scheduled for 09:00 UTC (11:00 Berlin time), weekdays"

### Update-first rule

Before creating a new job, always `list` existing jobs first.
If a matching job already exists, `update` it instead of creating a duplicate.
Never create duplicate jobs for the same purpose.

### Schedule types

| Type | Parameter | Use case |
|------|-----------|----------|
| Interval | `every_seconds` | Sub-minute or simple intervals (e.g. every 30s, every 5min) |
| Cron | `cron_expr` | Calendar-based schedules (e.g. weekdays at 9am) |
| One-time | `at` | Single future execution (ISO 8601 datetime in UTC) |

### Cron expression format

Five fields: `MIN HOUR DOM MON DOW`

- MIN: 0-59, HOUR: 0-23, DOM: 1-31, MON: 1-12, DOW: 0-6 (0=Sun)
- Wildcards: `*` (any), `*/5` (every 5), `1-5` (range), `1,15` (list)
- Examples: `*/5 * * * *` (every 5 min), `0 9 * * 1-5` (weekdays 9am), `30 18 * * 0` (Sun 6:30pm)

### Confirmation format

Always confirm with the user before add/remove/update:

```
Schedule: every 10 minutes
Message: "Use web_search to check..."
Next run: in 10 minutes
```
