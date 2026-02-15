# Sandboxing Architecture

Autobot uses **kernel-level sandboxing** to safely restrict LLM file access. This document explains how it works.

## Overview

```
┌─────────────────────────────────────┐
│ Host System (unrestricted)         │
│                                     │
│  ┌──────────────────────────────┐  │
│  │ autobot (main process)       │  │  ← Your agent, API calls, config
│  │  PID: 1234                   │  │    Full system access
│  │                              │  │
│  │  Spawns ↓                    │  │
│  └──────────────────────────────┘  │
│                                     │
│  ┌─────────────────────────────────────────┐
│  │ Kernel Sandbox (restricted)             │
│  │                                          │
│  │  ┌───────────────────────────────────┐  │
│  │  │ autobot (sandbox server mode)     │  │  ← File operations only
│  │  │  PID: 1235                        │  │    Workspace access ONLY
│  │  │                                   │  │
│  │  │  Executes:                        │  │
│  │  │   - read_file                     │  │
│  │  │   - write_file                    │  │
│  │  │   - list_dir                      │  │
│  │  │   - exec (shell commands)         │  │
│  │  └───────────────────────────────────┘  │
│  │                                          │
│  │  Kernel enforces:                        │
│  │   ✓ Can read/write: /workspace/*        │
│  │   ✗ Cannot access: /etc/passwd          │
│  │   ✗ Cannot access: ~/.ssh/              │
│  │   ✗ Cannot access: $HOME/.env           │
│  └─────────────────────────────────────────┘
└─────────────────────────────────────┘

        IPC: Unix domain socket
```

## Single Binary, Two Processes

Autobot uses **one binary file** that runs in **two modes**:

### Mode 1: Normal Agent (unrestricted)
```bash
$ autobot agent
# Main process - handles agent logic, API calls, secrets
```

### Mode 2: Sandbox Server (restricted)
```bash
$ autobot __internal_sandbox_server__ /tmp/socket.sock /workspace
# Spawned process - runs inside kernel sandbox
# Hidden from user, managed automatically
```

**User only sees one command, but gets two processes for safety.**

## How It Works

### 1. Agent Starts

```crystal
# User runs:
$ autobot agent

# Autobot initializes:
registry = Tools.create_registry(
  workspace: Path["/workspace"],
  sandbox_config: "auto"  # Detects available sandbox
)

# Creates SandboxService:
service = SandboxService.new(workspace, Sandbox::Type::Bubblewrap)
service.start  # Spawns autobot in sandbox mode
```

### 2. Sandbox Process Spawns

**Linux (bubblewrap):**
```bash
bwrap \
  --ro-bind /usr /usr \
  --ro-bind /bin /bin \
  --bind /workspace /workspace \  # ONLY writable directory
  --unshare-all \
  --proc /proc \
  --dev /dev \
  --tmpfs /tmp \
  --chdir /workspace \
  -- /usr/local/bin/autobot __internal_sandbox_server__ /tmp/socket.sock /workspace
```

**macOS (Docker - required for full isolation):**
```bash
docker run --rm \
  -v /workspace:/workspace:rw \
  -v /tmp/socket.sock:/tmp/socket.sock \
  -v /usr/local/bin/autobot:/usr/local/bin/autobot:ro \
  --memory 512m --cpus 1 \
  alpine:latest \
  /usr/local/bin/autobot __internal_sandbox_server__ /tmp/socket.sock /workspace
```

**Why Docker on macOS?**
- macOS sandbox-exec only restricts writes, NOT reads
- Write-only sandboxing is insufficient (agent could read ~/.ssh/, /etc/passwd)
- Docker provides full isolation (read + write restrictions)
- Apple is deprecating sandbox-exec anyway

**Docker (universal):**
```bash
docker run --rm \
  -v /workspace:/workspace:rw \
  -v /tmp/socket.sock:/tmp/socket.sock \
  --memory 512m --cpus 1 \
  alpine:latest \
  /usr/local/bin/autobot __internal_sandbox_server__ /tmp/socket.sock /workspace
```

### 3. Operations Execute

**User request:**
```
> Agent: "read memory/MEMORY.md"
```

**Internal flow:**
```
1. Main process (unrestricted):
   tool = ReadFileTool.new(sandbox_service)
   tool.execute({"path" => "memory/MEMORY.md"})

2. SandboxService sends via Unix socket:
   {"id": "req-1", "op": "read_file", "path": "memory/MEMORY.md"}

3. Sandbox server (restricted) receives:
   - Resolves path: /workspace/memory/MEMORY.md
   - Checks: path within workspace? ✓
   - Reads file (kernel allows - within workspace)
   - Returns: {"id": "req-1", "status": "ok", "data": "..."}

4. Main process receives result:
   Returns content to agent
```

**Attack attempt:**
```
> Agent (compromised): "read /etc/passwd"

1. Main process sends:
   {"id": "req-2", "op": "read_file", "path": "/etc/passwd"}

2. Sandbox server rejects:
   - Path is absolute? ✗ REJECTED
   - Returns: {"id": "req-2", "status": "error", "error": "Absolute paths not allowed"}

# Even if server had a bug and tried to read /etc/passwd:
# Kernel would block it - file is outside namespace/container
```

## Security Layers

**Defense in depth:**

1. **Application layer** (sandbox server code)
   - Rejects absolute paths
   - Rejects `..` traversal
   - Validates path is workspace-relative

2. **Kernel layer** (OS enforces)
   - Process cannot access files outside workspace
   - Even if application has bugs
   - Cannot be bypassed from inside sandbox

3. **IPC layer** (Unix socket)
   - Only JSON protocol allowed
   - No arbitrary code execution
   - Structured request/response only

## Recovery Mechanism

If sandbox crashes during operation:

```
1. Main process detects: IO::Error (socket closed)

2. Automatic recovery (up to 2 attempts):
   - Stop crashed process
   - Clean up old socket
   - Spawn new sandbox process
   - Reconnect socket
   - Retry failed operation

3. If recovery succeeds:
   ✓ Operation completes
   ⚠ User sees brief warning

4. If recovery fails:
   ✗ Clear error message
   → User restarts agent
```

## Platform Support

| Platform | Technology | Startup | Per Operation | Security |
|----------|-----------|---------|---------------|----------|
| **Linux** | bubblewrap | ~10ms | ~2-3ms | Full isolation (namespaces) ✅ |
| **macOS** | Docker | ~100ms | ~5-10ms | Full isolation (containers) ✅ |
| **Windows** | Docker (WSL2) | ~150ms | ~10-15ms | Full isolation (containers) ✅ |

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
# Docker Desktop required for full isolation
# Download from: https://docs.docker.com/desktop/install/mac-install/

# Verify Docker is running
docker run --rm alpine:latest echo "Sandbox ready"
```

**Why Docker?** macOS sandbox-exec cannot provide read-level isolation (only write restrictions), making it insufficient for security.

### Universal (Docker)
```bash
# Install Docker for your platform
https://docs.docker.com/engine/install/

# Verify
docker run --rm alpine:latest echo "Sandbox ready"
```

## Verification

**Test sandboxing works:**
```bash
$ autobot agent

> Agent: "read /etc/passwd"

# Should see error:
Error: Absolute paths not allowed

# Even if you try:
> Agent: "read ../../../etc/passwd"

Error: Parent directory traversal not allowed
```

**Check processes:**
```bash
$ ps aux | grep autobot
user  1234  autobot agent              # Main process
user  1235  autobot __internal_sando... # Sandbox (hidden)
```

## Configuration

Sandbox can be configured in `config.yml`:

```yaml
tools:
  sandbox: auto  # auto | bubblewrap | docker | none

  # Advanced options:
  use_sandbox_service: true      # Use persistent service (recommended)
  exec_timeout: 120              # Command timeout (seconds)
  exec_deny_patterns:            # Block dangerous commands
    - "rm -rf /"
    - ":(){ :|:& };:"            # Fork bomb
```

**Options:**
- `auto`: Auto-detect best available (recommended)
  - Linux → bubblewrap (fast)
  - macOS → Docker (full isolation)
- `bubblewrap`: Force bubblewrap (Linux only)
- `docker`: Force Docker (all platforms)
- `none`: Disable sandboxing (UNSAFE - tests only)

## Troubleshooting

### Error: "No sandbox tool found"

**Problem:** No sandboxing tool installed

**Fix:**
```bash
# Linux: Install bubblewrap
sudo apt install bubblewrap

# macOS: sandbox-exec should be pre-installed
which sandbox-exec

# Universal: Install Docker
# https://docs.docker.com/engine/install/
```

### Error: "Failed to start sandbox service"

**Problem:** Binary or socket issues

**Fix:**
```bash
# 1. Verify binary exists
ls -lh $(which autobot)

# 2. Check /tmp is writable
touch /tmp/test && rm /tmp/test

# 3. Try Docker fallback
autobot agent --sandbox docker
```

### Sandbox crashes during operation

**Problem:** Process killed (OOM, signal)

**Expected:** Auto-recovery handles this
```
⚠ Sandbox service communication failed (attempt 1/2)
ℹ Attempting to recover sandbox service...
✓ Sandbox service recovered successfully
```

**If recovery fails:**
```bash
# Restart agent
^C
autobot agent
```

## Development

### Running Without Sandbox (Tests)

Tests automatically disable sandboxing:

```crystal
# Tests pass sandbox_service: nil
tool = ReadFileTool.new(nil)

# Tool uses direct file operations (fast, no overhead)
tool.execute({"path" => "test.txt"})  # Direct File.read
```

### Testing Sandbox Behavior

```crystal
# spec/security_spec.cr tests sandbox escaping
it "prevents reading system files" do
  tool = ReadFileTool.new(sandbox_service)
  result = tool.execute({"path" => "/etc/passwd"})
  result.error?.should be_true
end
```

### Manual Testing

```bash
# Start sandbox server manually (for debugging)
$ autobot __internal_sandbox_server__ /tmp/test.sock /tmp/workspace &

# Send request via socket
$ echo '{"id":"1","op":"read_file","path":"test.txt"}' | nc -U /tmp/test.sock

# Should receive:
{"id":"1","status":"ok","data":"file contents"}
```

## Performance

**Benchmark: 1000 file operations**

| Setup | Time | Per Operation |
|-------|------|---------------|
| No sandbox | 450ms | 0.45ms |
| Sandbox (persistent) | 2.8s | 2.8ms |
| Sandbox (spawn per-op) | 52s | 52ms |

**Takeaway:** Persistent sandbox service adds ~2-3ms overhead (acceptable), while spawning per operation adds ~50ms (too slow).

## Security Properties

**What sandboxing prevents:**

✅ Reading system files (`/etc/passwd`, `/etc/shadow`)
✅ Reading home directory (`~/.ssh/`, `~/.aws/`)
✅ Writing outside workspace
✅ Accessing secrets in parent directories
✅ Network attacks via filesystem (symlinks to `/dev`)
✅ Fork bombs and resource exhaustion (Docker limits)

**What sandboxing does NOT prevent:**

⚠️ Network attacks (agent has network access)
⚠️ API key theft (main process has keys)
⚠️ DoS via API calls
⚠️ Social engineering (user approves actions)

**Defense in depth:** Sandboxing is ONE layer. Also use:
- API key scoping
- Rate limiting
- User confirmation for sensitive actions
- Audit logs

## FAQ

**Q: Why two processes instead of one?**
A: Kernel sandboxing works per-process. Can't sandbox part of a process - it's all or nothing.

**Q: Can I disable sandboxing?**
A: Only for tests. Production requires sandboxing for safety.

**Q: What if sandbox crashes?**
A: Automatic recovery (up to 2 attempts), then fail with clear error.

**Q: Does this work on Windows?**
A: Via Docker (using WSL2). Native Windows sandboxing not yet implemented.

**Q: How do I verify it's working?**
A: Try `read /etc/passwd` - should fail with "Absolute paths not allowed"

**Q: Performance impact?**
A: ~2-3ms per operation. Negligible for typical agent workloads.

**Q: What about plugins/bash tools?**
A: All tools use the same sandbox service - no exceptions.

---

**Summary:** Autobot uses kernel-level sandboxing with a persistent service process for high-performance, secure LLM file access. Single binary, automatic recovery, multi-platform support.
