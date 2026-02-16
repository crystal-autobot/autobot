# Security

Production-grade security checklist for deploying Autobot safely.

## 1. Restrict Who Can Talk to the Bot (DENY-BY-DEFAULT)

**IMPORTANT:** Empty `allow_from` = DENY ALL (secure default since v0.1.0)

```yaml
channels:
  telegram:
    allow_from: ["@alice", "123456789"]  # Allowlist specific users (recommended)
    # allow_from: ["*"]                  # Allow anyone (use with caution!)
    # allow_from: []                     # Deny all (secure default)
```

**For Slack:** Prefer `mention` policy in group channels to prevent unauthorized access.

---

## 2. Kernel-Enforced Workspace Sandbox (REQUIRED FOR PRODUCTION)

Autobot uses kernel-level sandboxing to restrict LLM file access to a designated workspace directory.

### Quick Setup

**Linux (bubblewrap - recommended):**
```bash
sudo apt install bubblewrap  # Ubuntu/Debian
sudo dnf install bubblewrap  # Fedora
sudo pacman -S bubblewrap    # Arch
```

**macOS/Windows (Docker):**
```bash
# Install Docker Desktop
# https://docs.docker.com/engine/install/
```

### Configuration

```yaml
tools:
  sandbox: auto  # auto | bubblewrap | docker | none (default)
```

### What It Protects Against

- ✅ Reading system files (`/etc/passwd`, `~/.ssh/`)
- ✅ Writing outside workspace
- ✅ Path traversal (`../../../etc/passwd`)
- ✅ Absolute path exploits (`/etc/passwd`)
- ✅ Symlink attacks

**For detailed information**, see [docs/sandboxing.md](sandboxing.md)

### Best Practices

- ✅ Always use sandboxing in production (`sandbox: auto` or specific type)
- ✅ Install bubblewrap for development (lightweight, fast)
- ✅ Use Docker for production deployments
- ✅ Keep workspace scoped to a dedicated directory, not your home folder
- ⚠️ Never use `sandbox: none` in production (development-only)
- ⚠️ Never place `.env` files inside workspace (blocked automatically)

---

## 3. SSRF Protection (ALWAYS ENABLED)

Built-in protection against Server-Side Request Forgery:

**Blocked automatically:**
- Private IP ranges (10.x, 192.168.x, 172.16-31.x)
- Localhost/loopback (127.x, ::1)
- Cloud metadata endpoints (169.254.169.254)
- Link-local addresses (169.254.x, fe80:)
- Alternate IP notation (octal: 0177.0.0.1, hex: 0x7f.0.0.1)
- IPv6 private ranges (fc00::/7, fd00::/8)

**All DNS records validated** to prevent DNS rebinding attacks.

---

## 4. Keep Secrets Out of Files

### .env File Protection (v0.2.0+)

Autobot enforces strict `.env` file protection:

**Automatic blocks (LLM cannot access):**
- `.env` files blocked in ReadFileTool (read, list directory)
- `.env` files blocked in ExecTool (commands like `cat .env`)
- Pattern matching: `.env`, `.env.local`, `.env.production`, `secrets.env`, etc.

**Configuration validation (`autobot doctor`):**
- ❌ Error: Plaintext secrets in `config.yml`
- ❌ Error: `.env` permissions not 0600
- ❌ Error: `.env` inside workspace (exposes to LLM)
- ⚠️ Warning: Missing `.env` file

**Example secure config:**
```yaml
# config.yml (safe for LLM to read)
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"  # References .env

# .env (NEVER accessible to LLM)
ANTHROPIC_API_KEY=sk-ant-your-secret-key
```

**File locations:**
- ✅ `./autobot/.env` (outside workspace)
- ✅ `./.env` (outside workspace)
- ❌ `./workspace/.env` (inside workspace - BLOCKED by validation)

### Log Sanitization

**Automatic log sanitization** redacts:
- API keys (sk-ant-, sk-, AKIA, etc.)
- Bearer tokens
- OAuth tokens
- Passwords in URLs/params
- Authorization headers

---

## 5. Configuration Validation (`autobot doctor`)

Use `autobot doctor` to verify security configuration before deployment:

```bash
autobot doctor          # Check for errors and warnings
autobot doctor --strict # Fail on any warning (CI/CD)
```

**Security checks performed:**

**❌ Errors (blocks deployment):**
- Sandbox enabled but not available
- Plaintext secrets detected in `config.yml`
- `.env` file permissions not 0600
- `.env` file inside workspace directory
- No LLM provider configured

**⚠️ Warnings (review recommended):**
- Gateway bound to 0.0.0.0 (network exposure)
- Channel authorization not configured (empty `allow_from`)
- Missing `.env` file
- Workspace restrictions disabled
- Channels enabled without tokens

**Example output:**
```
❌ ERRORS (1):
  • CRITICAL: .env file has insecure permissions (644). Run: chmod 600 /path/.env

⚠️  WARNINGS (1):
  • Gateway is bound to 0.0.0.0 (all network interfaces). Use '127.0.0.1' for localhost-only access.

Summary: 1 errors, 1 warnings, 0 info
```

**Integration:**
- Run automatically on `autobot gateway` startup
- Exit code 1 on errors (stops deployment)
- Use `--strict` in CI/CD pipelines to catch warnings

---

## 6. Review Logs & Monitor Access

```bash
# Check for ACCESS DENIED (security blocks)
grep "ACCESS DENIED" ./logs/autobot.log

# Tool activity
grep "Executing tool:" ./logs/autobot.log

# Token usage
grep "Tokens:" ./logs/autobot.log
```

**Log levels:**
- `INFO` - Successful operations
- `WARN` - Failed operations or ACCESS DENIED
- `ERROR` - Exceptions and critical failures

---

## 7. File Permissions (AUTOMATIC)

Autobot automatically sets restrictive permissions on sensitive files:
- **Config files:** `0600` (user read/write only)
- **Session files:** `0600` (user read/write only)
- **Cron store:** `0600` (user read/write only)
- **Directories:** `0700` (user access only)

**Validation:**
- `autobot doctor` checks `.env` permissions (must be 0600)
- Automatic enforcement on file creation

---

## 8. Cron Job Isolation (AUTOMATIC)

Jobs are automatically isolated by owner (channel:chat_id):
- Users can only list/remove their own jobs
- Cross-user tampering prevented

---

## 9. Rate Limiting (PER-SESSION)

Rate limits are enforced per-session to prevent:
- One user exhausting limits for others
- Abuse of expensive operations (web search, LLM calls)

---

## 10. Isolate Runtime

**Recommended deployment:**
- Run with least-privileged user account
- Use containerization (Docker) or systemd service boundaries
- Bind gateway to localhost only (`host: 127.0.0.1`) unless external access needed
- Use reverse proxy with TLS for external access

**Production security checklist:**
- [ ] `autobot doctor --strict` passes
- [ ] Dedicated user account (not root)
- [ ] `.env` permissions (0600)
- [ ] `.env` outside workspace
- [ ] TLS configured (Let's Encrypt)
- [ ] Gateway bound to localhost
- [ ] Reverse proxy for external access
- [ ] Resource limits configured
- [ ] Log monitoring enabled

---

## 11. Known Limitations

**WhatsApp Bridge:** WebSocket connection has no authentication (ws://).
- **Mitigation:** Only run bridge on localhost
- **TODO:** HMAC/JWT authentication in future release
