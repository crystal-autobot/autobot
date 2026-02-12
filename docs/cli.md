# CLI Reference

## Commands

- `autobot onboard`: Initialize config and workspace
- `autobot agent`: Chat in terminal (interactive or single message)
- `autobot gateway`: Run the channel gateway
- `autobot cron`: Manage scheduled jobs
- `autobot status`: Show runtime/config status
- `autobot version`: Show version/build info
- `autobot help`: Show CLI help

## Global Options

- `-c, --config PATH`
- `-v, --verbose`
- `--version`

## `agent`

```bash
autobot agent
autobot agent -m "Explain Crystal fibers"
autobot agent -s cli:project-x -m "status"
autobot agent --no-markdown
autobot agent --logs
```

## `gateway`

```bash
autobot gateway
autobot gateway -p 8080
autobot gateway -v
```

## `cron`

```bash
autobot cron list
autobot cron list -a

autobot cron add -n daily -m "Daily summary" --cron "0 9 * * 1-5"
autobot cron add -n health -m "Check health" -e 300
autobot cron add -n reminder -m "Meeting" --at "2026-02-12T14:55:00Z"

autobot cron add -n report -m "Daily report" --cron "0 18 * * *" \
  -d --channel telegram --to "@team"

autobot cron remove <job-id>
autobot cron enable <job-id>
autobot cron enable <job-id> --disable
autobot cron run <job-id>
autobot cron run <job-id> --force
```

## `status` and `version`

```bash
autobot status
autobot version
```
