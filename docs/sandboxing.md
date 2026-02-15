# Sandboxing Architecture

Autobot uses **kernel-level sandboxing** to safely restrict LLM file access. This document explains the hybrid architecture with two execution modes.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│ Hybrid Sandboxing: Simple Default + Optional Performance    │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ DEFAULT: Sandbox.exec (~50ms/op)                     │  │
│  │  • Works everywhere, zero setup                       │  │
│  │  • Single binary                                      │  │
│  │  • Spawns sandbox per operation                       │  │
│  │  • Uses shell commands (cat, ls, base64)             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ OPTIONAL: autobot-server (~3ms/op)                   │  │
│  │  • 15x faster performance                             │  │
│  │  • Persistent sandbox process                         │  │
│  │  • Requires separate install                          │  │
│  │  • Power users only                                   │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Why Two Modes?

**Previous approach:** Single-binary internal server
- ❌ Binary compatibility issues (macOS binary can't run in Linux containers)
- ❌ Over-engineered
- ❌ Broke on macOS with Docker

**Current approach:** Hybrid architecture
- ✅ Default works everywhere (shell commands work in any container)
- ✅ Optional performance upgrade path
- ✅ No binary compatibility issues
- ✅ Graceful fallback

## Default Mode: Sandbox.exec

### How It Works

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

**Performance:** ~50ms per operation (acceptable for most use cases)

## Optional Mode: autobot-server (Linux Only)

### When to Use

Install autobot-server if you:
- **Run on Linux** with bubblewrap
- Need **15x faster** file operations (~3ms vs ~50ms)
- Have **high-frequency** file access patterns

**Not available on macOS/Windows** - Docker overhead dominates, so autobot-server doesn't help.
**Most users don't need this** - the default mode is fast enough.

### How It Works

A persistent sandbox process communicates via Unix socket:

```
┌─────────────────┐           ┌─────────────────────┐
│ autobot (main)  │  socket   │ autobot-server      │
│ PID: 1234       │◄─────────►│ PID: 1235 (sandbox) │
│ unrestricted    │  JSON/IPC │ workspace only      │
└─────────────────┘           └─────────────────────┘
```

### Installation (Linux Only)

**Linux AMD64:**
```bash
curl -L https://github.com/crystal-autobot/sandbox-server/releases/latest/download/autobot-server-linux-amd64 \
  -o /usr/local/bin/autobot-server
chmod +x /usr/local/bin/autobot-server
```

**Linux ARM64:**
```bash
curl -L https://github.com/crystal-autobot/sandbox-server/releases/latest/download/autobot-server-linux-arm64 \
  -o /usr/local/bin/autobot-server
chmod +x /usr/local/bin/autobot-server
```

**Note:** autobot-server only works on Linux with bubblewrap. macOS/Windows users should use the default Sandbox.exec mode (Docker overhead makes autobot-server unnecessary).

### Auto-Detection (Linux Only)

On Linux, autobot automatically detects and uses autobot-server if installed:

```bash
$ autobot agent  # On Linux

✓ Sandbox: bubblewrap (Linux namespaces)
→ Sandbox mode: autobot-server (persistent, ~3ms/op)
```

If not installed:
```bash
→ Sandbox mode: Sandbox.exec (bubblewrap, ~50ms/op)
```

**On macOS/Windows:** Always uses Sandbox.exec + Docker (autobot-server not applicable).

### Graceful Fallback

If autobot-server fails to start, autobot automatically falls back to Sandbox.exec:

```bash
⚠ autobot-server failed to start: socket error
→ Falling back to Sandbox.exec
```

**No manual intervention needed** - everything just works.

## Platform Support

| Platform | Sandbox Tool | Default (Sandbox.exec) | Optional (autobot-server) |
|----------|-------------|------------------------|---------------------------|
| **Linux** | bubblewrap | ~50ms/op | ~3ms/op (15x faster) ✅ |
| **macOS** | Docker | ~50ms/op | Not applicable |
| **Windows** | Docker (WSL2) | ~50ms/op | Not applicable |

**Note:** autobot-server only works on Linux with bubblewrap. Docker overhead on macOS/Windows makes the performance gain negligible.

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
```

**Options:**
- `auto` - Auto-detect best available (recommended)
  - Tries: autobot-server → bubblewrap → Docker
- `bubblewrap` - Force bubblewrap (Linux only)
- `docker` - Force Docker (all platforms)
- `none` - Disable sandboxing (UNSAFE - tests only)

## Security Properties

### What Sandboxing Prevents

✅ Reading system files (`/etc/passwd`, `/etc/shadow`)
✅ Reading home directory (`~/.ssh/`, `~/.aws/credentials`)
✅ Writing outside workspace
✅ Accessing secrets in parent directories
✅ Path traversal attacks (`../../../etc/passwd`)
✅ Absolute path exploits (`/etc/passwd`)

### Security Layers

**Defense in depth:**

1. **Application layer** (path validation)
   - Rejects absolute paths
   - Rejects `..` traversal
   - Validates workspace-relative paths

2. **Shell escaping** (command injection prevention)
   - Single-quote escaping
   - Base64 encoding for file content

3. **Kernel layer** (OS enforces)
   - Process cannot access files outside workspace
   - Even if application has bugs
   - Cannot be bypassed from inside sandbox

### What Sandboxing Does NOT Prevent

⚠️ Network attacks (agent has network access)
⚠️ API key theft (main process has keys)
⚠️ DoS via API calls
⚠️ Social engineering (user approves actions)

**Defense in depth:** Use API key scoping, rate limiting, and audit logs.

## Performance

**Benchmark: 1000 file operations**

| Mode | Time | Per Operation | Use Case |
|------|------|---------------|----------|
| autobot-server | 3.2s | 3.2ms | Performance-critical workloads |
| Sandbox.exec | 52s | 52ms | Normal use (default) |
| No sandbox | 450ms | 0.45ms | Tests only (UNSAFE) |

**Takeaway:**
- Default (~50ms/op) is acceptable for most use cases
- Install autobot-server for 15x speedup if needed

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

### Slow performance on Linux

**Problem:** Each operation takes ~50ms on Linux

**Solution:** Install autobot-server for 15x speedup (Linux only)
```bash
curl -L https://github.com/crystal-autobot/sandbox-server/releases/latest/download/autobot-server-linux-amd64 \
  -o /usr/local/bin/autobot-server
chmod +x /usr/local/bin/autobot-server
```

**Note:** Not applicable on macOS/Windows (Docker overhead dominates).

## Development

### Running Without Sandbox (Tests)

Tests automatically disable sandboxing:

```crystal
# Tests pass sandbox_service: nil, workspace: nil
tool = ReadFileTool.new(nil, nil)

# Tool uses direct file operations (fast, no overhead)
tool.execute({"path" => "test.txt"})  # Direct File.read
```

### Testing Sandbox Behavior

```crystal
# spec/security_spec.cr tests sandbox restrictions
it "prevents reading system files" do
  tool = ReadFileTool.new(nil, workspace)
  result = tool.execute({"path" => "/etc/passwd"})
  result.error?.should be_true
end
```

## FAQ

**Q: Do I need to install autobot-server?**
A: No! The default Sandbox.exec works fine for most users. Install autobot-server only if you're on Linux and need 15x faster performance. Not available on macOS/Windows.

**Q: What if autobot-server crashes?**
A: Autobot automatically falls back to Sandbox.exec. No manual intervention needed.

**Q: Why not always use autobot-server?**
A: Keeping it optional reduces complexity for most users. Single binary + zero setup = better experience.

**Q: Does this work on Windows?**
A: Yes, via Docker with WSL2 backend.

**Q: How do I verify sandboxing works?**
A: Try reading `/etc/passwd` - should fail with "Absolute paths not allowed"

**Q: What's the performance impact?**
A: Default ~50ms/op is acceptable for most use cases. On Linux, install autobot-server for ~3ms/op. On macOS/Windows, Docker overhead dominates so autobot-server doesn't help.

**Q: Can I disable sandboxing?**
A: Only for tests. Production requires sandboxing for safety.

---

**Summary:** Autobot provides a hybrid sandboxing architecture with a simple default that works everywhere (~50ms/op) and an optional performance mode for power users (~3ms/op). No manual configuration needed - autobot automatically detects and uses the best option available.
