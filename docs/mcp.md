# MCP (Model Context Protocol)

Autobot can connect to external MCP servers to extend the LLM's capabilities with remote tools. MCP servers expose tools via JSON-RPC 2.0 over stdio — autobot discovers them at startup and registers them as regular tools so the LLM can use them transparently.

## How It Works

1. On startup, autobot reads the `mcp.servers` section from `config.yml`
2. For each server, it spawns the command as a child process
3. Performs the MCP protocol handshake (initialize + notifications/initialized)
4. Calls `tools/list` to discover available tools
5. Registers each tool as `mcp_{server}_{tool}` in the tool registry
6. The LLM sees these as native tools and can call them like any other

## Configuration

Add an `mcp` section to your `config.yml`:

```yaml
mcp:
  servers:
    garmin:
      command: "uvx"
      args: ["--python", "3.12", "--from", "git+https://github.com/Taxuspt/garmin_mcp", "garmin-mcp"]
      env:
        GARMIN_EMAIL: "${GARMIN_EMAIL}"
        GARMIN_PASSWORD: "${GARMIN_PASSWORD}"
    github:
      command: "npx"
      args: ["-y", "@modelcontextprotocol/server-github"]
      env:
        GITHUB_TOKEN: "${GITHUB_TOKEN}"
```

Each server entry has:

| Field | Type | Description |
|-------|------|-------------|
| `command` | string | Executable to spawn (must be in PATH) |
| `args` | string[] | Command-line arguments |
| `env` | map | Environment variables passed to the process |

Environment variables support `${VAR}` expansion from your `.env` file or shell environment.

## Tool Naming

MCP tools are prefixed to avoid collisions with built-in tools:

```
mcp_{server_name}_{tool_name}
```

All characters outside `[a-z0-9_]` are replaced with underscores. For example:

| Server | Remote Tool | Registered As |
|--------|-------------|---------------|
| garmin | get_activities | `mcp_garmin_get_activities` |
| github | list-repos | `mcp_github_list_repos` |

## Security

MCP servers run as regular child processes (not sandboxed) because they typically need network access for external APIs. However, several safeguards are in place:

- **Env isolation**: Only explicitly configured env vars are passed to the process, plus `PATH`, `HOME`, and `LANG` from the host
- **No workspace sharing**: MCP processes do not receive access to autobot's workspace directory
- **Timeouts**: 30s for initialization handshake, 60s for tool calls
- **Response truncation**: Tool results are capped at 50KB to prevent memory issues
- **No auto-restart**: If a server crashes, its tools return errors until autobot is restarted

## Troubleshooting

### Server fails to start

Check that the command is installed and in your PATH:

```bash
which uvx   # or npx, or whatever command you configured
```

Enable debug logging to see stderr output from MCP servers:

```bash
LOG_LEVEL=debug autobot agent -m "test"
```

### Tools not discovered

Verify the server responds to the MCP protocol. You can test manually:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}' | npx -y @modelcontextprotocol/server-github
```

### Timeouts

If a server takes longer than 30s to initialize (e.g. downloading dependencies on first run), the handshake will fail. Pre-install dependencies before running autobot:

```bash
# For Python-based servers
uvx --python 3.12 --from git+https://... garmin-mcp --help

# For Node-based servers
npx -y @modelcontextprotocol/server-github --help
```
