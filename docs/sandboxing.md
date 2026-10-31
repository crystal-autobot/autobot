# Sandboxing Architecture

Autobot uses **kernel-level sandboxing** to safely restrict LLM file access. Each operation spawns a sandboxed process via bubblewrap or Docker.

## Overview

```
┌──────────────────────────────────────────────────────┐
│ Sandbox.exec                                          │
│  • Works everywhere, zero setup                       │
│  • Single binary                                      │
│  • Spawns sandbox per operation                       │
│  • Uses shell commands (cat, ls, base64)             │
└──────────────────────────────────────────────────────┘
```

## How It Works

Instead of spawning a persistent server, we spawn a sandboxed process for each operation:

```crystal
# Read file
Sandbox.exec("cat #{shell_escape(path)} 2>&1", workspace, timeout: 10)

# Write file (using base64 to avoid escaping issues)
encoded = Base64.strict_encode(content)
Sandbox.exec("printf '%s' '#{encoded}' | base64 -d > #{shell_escape(path)}", workspace, timeout: 30)

# List directory
Sandbox.exec("ls -1a #{shell_escape(path)} 2>&1", workspace, timeout: 10)
```

### Why Shell Commands?

- **Alpine container has `/bin/sh` built-in** - no binary compatibility issues
- **We pass strings, not binaries** - works everywhere
- **Works in Docker/bubblewrap/any Linux container**
- **Simple and reliable**

### Execution (Linux - bubblewrap)

```bash
bwrap \
  --ro-bind /usr /usr \
  --ro-bind /lib /lib \
  --ro-bind /bin /bin \
  --ro-bind /sbin /sbin \
  --bind /workspace /workspace \
  --proc /proc \
  --dev /dev \
  --unshare-all \
  --share-net \
  --die-with-parent \
  --chdir /workspace \
  --ro-bind /etc/alternatives /etc/alternatives \
  --ro-bind /etc/ld.so.cache /etc/ld.so.cache \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind /etc/ssl /etc/ssl \
  --tmpfs /tmp \
  -- sh -c "cat file.txt"
```

The `/etc` lines are a sample: every path in `Sandbox::SYSTEM_CONFIG_PATHS` that exists on the host is bound read-only the same way, and so is `/lib64` when present.

**What the sandbox can see**

| Path | Access | Why |
|------|--------|-----|
| `/usr`, `/lib`, `/lib64`, `/bin`, `/sbin` | read-only | host-installed tools and libraries |
| `/etc/alternatives` | read-only | Debian-based hosts resolve `python3`, `awk`, `which`, `cc` and libraries such as `libblas.so.3` through it |
| `/etc/ld.so.cache`, `/etc/ld.so.conf`, `/etc/ld.so.conf.d` | read-only | dynamic loader library lookup |
| `/etc/resolv.conf`, `/etc/hosts`, `/etc/nsswitch.conf` | read-only | DNS resolution |
| `/etc/ssl`, `/etc/ca-certificates` | read-only | TLS trust store for `curl`, Python and friends |
| `/etc/localtime` | read-only | local time zone |
| `/etc/passwd`, `/etc/group` | read-only | user and group names (`whoami`, `ls -l`) |
| `/etc/matplotlibrc` | read-only | Debian's `python3-matplotlib` keeps its only config file here |
| workspace | read-write | the bot's files |
| `/proc`, `/dev`, `/tmp` | private | fresh per command, `/tmp` is an empty tmpfs |

Each `/etc` entry is bound only when it exists on the host. Nothing else from the host is mounted: the rest of `/etc`, home directories, `/var`, `/opt` and `/srv` are not visible. The sandbox root is an empty tmpfs, so a command can create missing paths such as `$HOME`, but they vanish when it exits.

### Execution (macOS/Universal - Docker)

```bash
docker run --rm \
  --name autobot-sandbox-3f9a1c0b7d2e4a65 \
  -v /workspace:/workspace:rw \
  -w /workspace \
  --memory 512m --cpus 1 \
  alpine:latest \
  sh -c "cat file.txt"
```

Each command gets its own container name. When a command times out, the container is removed with `docker rm --force`, because stopping the `docker run` client alone leaves the container running.

## Platform Support

| Platform | Sandbox Tool |
|----------|-------------|
| **Linux** | bubblewrap (recommended) |
| **Linux** | Docker |
| **macOS** | Docker |
| **Windows** | Docker (WSL2) |

## Installation

### Linux (Recommended: bubblewrap)
```bash
# Ubuntu/Debian
sudo apt install bubblewrap

# Fedora
sudo dnf install bubblewrap

# Arch
sudo pacman -S bubblewrap
```

### macOS (Requires Docker)
```bash
# Docker Desktop required
# Download from: https://docs.docker.com/desktop/install/mac-install/

# Verify
docker run --rm alpine:latest echo "Sandbox ready"
```

**Why Docker on macOS?**

- macOS sandbox-exec only restricts writes, NOT reads
- Can't prevent reading `/etc/passwd`, `~/.ssh/`, etc.
- Docker provides full read+write isolation
- Apple is deprecating sandbox-exec anyway

### Windows (Docker via WSL2)
```bash
# Install Docker Desktop with WSL2 backend
# https://docs.docker.com/desktop/windows/wsl/

# Verify
docker run --rm alpine:latest echo "Sandbox ready"
```

## Configuration

Configure sandboxing in `config.yml`:

```yaml
tools:
  sandbox: auto  # auto | bubblewrap | docker | external | none (default: auto)
  docker_image: "python:3.14-alpine"  # optional, overrides Dockerfile.sandbox
  sandbox_env:   # env vars to forward into Docker sandbox (default: none)
    - HA_URL
    - MQTT_HOST
```

**Options:**

- `sandbox` — Sandbox mode
  - `auto` - Use bubblewrap when installed, otherwise Docker (recommended)
  - `bubblewrap` - Force bubblewrap (Linux only)
  - `docker` - Force Docker (all platforms)
  - `external` - You already run autobot inside your own container or VM; commands run directly there
  - `none` - Explicit opt-in to host exec; commands run on the host as the autobot user
- `docker_image` — Docker image to use for sandbox containers. Overrides `Dockerfile.sandbox` when set. Only applies when sandbox is `docker` or `auto` resolves to Docker.
- `sandbox_env` — List of environment variable names to forward into Docker containers. Only listed variables are forwarded — empty by default for security. Useful when sandbox scripts need access to specific env vars (e.g. `HA_URL`, `MQTT_HOST`).

### Sandbox modes

The mode is resolved once at boot and shared by `exec`, skill scripts, file tools and cron exec jobs, so no two parts of the bot can disagree about whether a command is sandboxed.

**`auto` never falls back to host exec.** When neither bubblewrap nor Docker is installed, boot stops with an error that names `none` and `external` as the explicit choices. There is no silent downgrade: a bot that was sandboxed yesterday cannot start running commands on the host today because a package went missing.

**`external`** is for deployments where autobot itself already runs inside a container or VM you control. Commands run directly in that environment, on the strength of your declaration. Autobot cannot verify it: the bot warns on every boot, and `autobot doctor` reports `Sandbox: external (not verified)`.

**`none`** is the explicit host-exec opt-in. `exec` and skill `bash_*` scripts keep working and run on the host as the user autobot runs as, with that user's files and credentials in reach of any command the model chooses. The bot prints this on every boot:

```
host exec enabled (sandbox: none): commands and skill scripts run on this host as <user>
```

and `autobot doctor` shows `Host exec: enabled by sandbox: none`. The mode must be set to `none` explicitly; nothing else grants host exec. Use it for local experiments, never for a bot that reads other people's messages.

### Host-mode path confinement

In `external` and `none` mode there is no kernel sandbox, so the executor confines the file tools itself. `read_file`, `write_file`, `edit_file` and `list_dir` resolve every path to its real path (symlinks followed) and refuse anything outside the workspace, the configured `tools.filesystem.roots`, or the workspace `skills/` directory for reads. A symlink inside the workspace that points at `~/.ssh` is refused, as is `/etc/passwd`. This is application-level checking and a weaker guarantee than the kernel sandbox: it covers the file tools, not what a command run by `exec` can do.

### .env files

Files named `.env`, `.env.*` or `*.env` are refused by `read_file`, `write_file` and `edit_file`, hidden from `list_dir`, and `exec` refuses a command that mentions one. This applies in every mode, including inside the sandbox, so a `.env` placed in the workspace by mistake still does not reach the model. Keep secrets outside the workspace anyway; see [Security](security.md).

### Filesystem roots

Independently of the sandbox backend, `tools.filesystem.roots` narrows the file tools to workspace subdirectories:

```yaml
tools:
  filesystem:
    roots: [notes, inbox]
```

The check runs in the executor before any sandboxed or direct operation, so it applies in every sandbox mode including `external` and `none`. Relative paths resolve against the workspace, `..` is normalized before the check, and a path outside every root returns a tool error naming the allowed directories. The `exec` tool is not narrowed by roots; the sandbox keeps it inside the workspace.

### Custom sandbox image (Dockerfile.sandbox)

When using Docker sandbox, the default `alpine:latest` image only includes basic shell tools. To add runtimes your bot needs (Python, SQLite, GitHub CLI, etc.), create a `Dockerfile.sandbox` in your bot folder:

```dockerfile
# Dockerfile.sandbox
FROM alpine:latest

RUN apk add --no-cache \
    python3 \
    curl \
    sqlite \
    git \
    github-cli
```

Autobot automatically builds and caches this as `autobot-sandbox` on first run. To rebuild after changes:

```bash
docker build -t autobot-sandbox -f Dockerfile.sandbox .
```

**Priority order:**

1. `tools.docker_image` in config.yml (explicit override)
2. `Dockerfile.sandbox` in bot folder (auto-built)
3. `alpine:latest` (default fallback)

**Note:** `autobot new` generates a default `Dockerfile.sandbox` with common tools. Edit it to match your needs.

**Note:** This only applies to Docker sandbox. With bubblewrap, host-installed tools are available automatically.

## Security Properties

### What Sandboxing Prevents

- Reading host files outside the read-only system paths (`/etc/shadow`, the rest of `/etc`)
- Reading home directory (`~/.ssh/`, `~/.aws/credentials`)
- Writing outside workspace
- Accessing secrets in parent directories
- Path traversal attacks (`../../../etc/passwd`)
- Absolute path exploits (`/etc/passwd`)

### How It Works

All filesystem and exec operations go through `SandboxExecutor`, which routes them to `Sandbox.exec`. Each operation spawns a sandboxed process (bubblewrap or Docker) that **cannot write outside the workspace and sees the host only through the read-only system paths listed above** — enforced by the OS kernel, not application code.

**Shell escaping** (single-quote escaping, base64 encoding for file content) prevents command injection within sandboxed commands.

**Note:** Plugin tools that call external CLIs (e.g. `gh`, `curl`) use `Process.run` with argument arrays (no shell interpretation) and run outside the sandbox since they need host resources (auth configs, SSL certs). MCP servers run on the host too.

### What Sandboxing Does NOT Prevent

- Network attacks (agent has network access)
- API key theft (main process has keys; tool results are redacted before they reach the model, see [Security](security.md#secrets-in-tool-output))
- DoS via API calls
- Social engineering (user approves actions)

**Defense in depth:** Use API key scoping, rate limiting, and audit logs.

## Troubleshooting

### Error: "No sandbox tool found"

**Problem:** No sandboxing tool installed

**Fix:**
```bash
# Linux: Install bubblewrap
sudo apt install bubblewrap

# macOS/Windows: Install Docker
# https://docs.docker.com/engine/install/
```

### Error: "Failed to start sandbox"

**Problem:** Binary or configuration issues

**Fix:**
```bash
# 1. Verify tools are installed
which bwrap    # Linux
which docker   # macOS/Windows

# 2. Check workspace exists
ls -ld /path/to/workspace

# 3. Try Docker fallback
autobot agent --sandbox docker
```

## Development

### Running With Host Exec (Local Experiments)

`sandbox: none` is an explicit opt-in to host exec, not a way to turn checks off. Commands and skill scripts run on the host as you, the bot warns on every boot, `autobot doctor` reports it, and the file tools stay confined to the workspace by real path. In code, the executor takes the resolved mode:

```crystal
executor = SandboxExecutor.new(workspace, Sandbox::Type::None)
tool = ReadFileTool.new(executor)

tool.execute({"path" => JSON::Any.new("test.txt")})     # direct File.read inside the workspace
tool.execute({"path" => JSON::Any.new("/etc/passwd")})  # refused: outside the workspace
```

### Testing Sandbox Behavior

```crystal
# spec/security_spec.cr tests sandbox restrictions
it "prevents reading system files" do
  executor = SandboxExecutor.new(workspace)
  tool = ReadFileTool.new(executor)
  result = tool.execute({"path" => JSON::Any.new("/etc/passwd")})
  result.error?.should be_true
end
```

## FAQ

**Q: Does this work on Windows?**
A: Yes, via Docker with WSL2 backend.

**Q: How do I verify sandboxing works?**
A: Try reading `/etc/passwd` - should fail with "Absolute paths not allowed"

**Q: Can I disable sandboxing?**
A: Only on purpose. Set `sandbox: none` and the bot runs commands on the host as you and says so on every boot. If autobot already runs inside your own container or VM, set `sandbox: external` instead. `auto` never falls back to either.

---

**Summary:** Autobot uses kernel-level sandboxing (bubblewrap or Docker) to restrict LLM file access. Each operation spawns a sandboxed process with shell commands, ensuring compatibility across all platforms with zero extra setup.
