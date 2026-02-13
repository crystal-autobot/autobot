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

## 2. Enable Workspace Sandbox (ENABLED BY DEFAULT)

```yaml
tools:
  restrict_to_workspace: true  # Default: true (recommended)
  exec:
    full_shell_access: false   # Default: false (SECURE - blocks shell features)
```

**What it protects against:**
- ✅ Absolute paths outside workspace (`cat /etc/passwd`)
- ✅ Quoted path bypass (`cat "/etc/hosts"`)
- ✅ working_dir parameter override
- ✅ Directory change commands (`cd /etc && ls`)
- ✅ Relative traversal (`cat ../../../etc`)
- ✅ Bare dotdot (`ls ..`)
- ✅ Variable bypass (`X=/etc/hosts; cat $X`)
- ✅ Shell features (pipes, redirects, chaining) when `full_shell_access: false`

**Shell Access Modes:**

| Mode | Shell Features | Security | Use Case |
|------|---------------|----------|----------|
| `full_shell_access: false` | ❌ Blocked | 🔒 Maximum | Production (default) |
| `full_shell_access: true` | ✅ Allowed | ⚠️ Reduced | Trusted environments |

**Best practice:**
- Keep workspace scoped to a dedicated directory, not your home folder
- Use `full_shell_access: false` unless you specifically need pipes/redirects
- Only enable `full_shell_access: true` when you fully trust command sources

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

Use environment variables for sensitive data:

```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"
```

**Automatic log sanitization** redacts:
- API keys (sk-ant-, sk-, AKIA, etc.)
- Bearer tokens
- OAuth tokens
- Passwords in URLs/params
- Authorization headers

---

## 5. Review Logs & Monitor Access

```bash
# Check for ACCESS DENIED (security blocks)
grep "ACCESS DENIED" ~/.config/autobot/logs/autobot.log

# Tool activity
grep "Executing tool:" ~/.config/autobot/logs/autobot.log

# Token usage
grep "Tokens:" ~/.config/autobot/logs/autobot.log
```

**Log levels:**
- `INFO` - Successful operations
- `WARN` - Failed operations or ACCESS DENIED
- `ERROR` - Exceptions and critical failures

---

## 6. File Permissions (AUTOMATIC)

Autobot automatically sets restrictive permissions on sensitive files:
- **Config files:** `0600` (user read/write only)
- **Session files:** `0600` (user read/write only)
- **Cron store:** `0600` (user read/write only)
- **Directories:** `0700` (user access only)

---

## 7. Cron Job Isolation (AUTOMATIC)

Jobs are automatically isolated by owner (channel:chat_id):
- Users can only list/remove their own jobs
- Cross-user tampering prevented

---

## 8. Rate Limiting (PER-SESSION)

Rate limits are enforced per-session to prevent:
- One user exhausting limits for others
- Abuse of expensive operations (web search, LLM calls)

---

## 9. Isolate Runtime

**Recommended deployment:**
- Run with least-privileged user account
- Use containerization (Docker) or systemd service boundaries
- Bind gateway to localhost only (`host: 127.0.0.1`) unless external access needed
- Use reverse proxy with TLS for external access

---

## 10. Known Limitations

**WhatsApp Bridge:** WebSocket connection has no authentication (ws://).
- **Mitigation:** Only run bridge on localhost
- **TODO:** HMAC/JWT authentication in future release
