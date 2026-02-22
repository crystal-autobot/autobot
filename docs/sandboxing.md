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
  --ro-bind /bin /bin \
  --bind /workspace /workspace \
  --unshare-all \
  --proc /proc \
  --dev /dev \
  --chdir /workspace \
  -- sh -c "cat file.txt"
```

### Execution (macOS/Universal - Docker)

```bash
docker run --rm \
  -v /workspace:/workspace:rw \
  -w /workspace \
  --memory 512m --cpus 1 \
  alpine:latest \
  sh -c "cat file.txt"
```

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
  sandbox: auto  # auto | bubblewrap | docker | none (default: auto)
  docker_image: "python:3.12-alpine"  # optional, default: alpine:latest
```

**Options:**

- `sandbox` — Sandbox backend
  - `auto` - Auto-detect best available (recommended)
  - `bubblewrap` - Force bubblewrap (Linux only)
  - `docker` - Force Docker (all platforms)
  - `none` - Disable sandboxing (UNSAFE - tests only)
- `docker_image` — Docker image to use for sandbox containers (default: `alpine:latest`). Set this when your commands need runtimes not available in Alpine (e.g. Python, Node.js). Only applies when sandbox is `docker` or `auto` resolves to Docker.

## Security Properties

### What Sandboxing Prevents

- Reading system files (`/etc/passwd`, `/etc/shadow`)
- Reading home directory (`~/.ssh/`, `~/.aws/credentials`)
- Writing outside workspace
- Accessing secrets in parent directories
- Path traversal attacks (`../../../etc/passwd`)
- Absolute path exploits (`/etc/passwd`)

### How It Works

All filesystem and exec operations go through `SandboxExecutor`, which routes them to `Sandbox.exec`. Each operation spawns a sandboxed process (bubblewrap or Docker) that **cannot access files outside the workspace** — enforced by the OS kernel, not application code.

**Shell escaping** (single-quote escaping, base64 encoding for file content) prevents command injection within sandboxed commands.

**Note:** Plugin tools that call external CLIs (e.g. `gh`, `curl`) use `Process.run` with argument arrays (no shell interpretation) and run outside the sandbox since they need host resources (auth configs, SSL certs).

### What Sandboxing Does NOT Prevent

- Network attacks (agent has network access)
- API key theft (main process has keys)
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

### Running Without Sandbox (Tests)

Tests automatically disable sandboxing:

```crystal
# Tests pass nil workspace to SandboxExecutor
executor = SandboxExecutor.new(nil)
tool = ReadFileTool.new(executor)

# Tool uses direct file operations (fast, no overhead)
tool.execute({"path" => JSON::Any.new("test.txt")})  # Direct File.read
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
A: Only for tests. Production requires sandboxing for safety.

---

**Summary:** Autobot uses kernel-level sandboxing (bubblewrap or Docker) to restrict LLM file access. Each operation spawns a sandboxed process with shell commands, ensuring compatibility across all platforms with zero extra setup.
