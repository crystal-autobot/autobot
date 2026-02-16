# Deployment Guide

Security-first deployment for Autobot with production-ready examples.

---

## System Requirements

**Sandboxing (required for workspace restrictions):**
- **bubblewrap** (recommended for development/Pi):
  ```bash
  # Ubuntu/Debian
  sudo apt install bubblewrap

  # Fedora
  sudo dnf install bubblewrap

  # Arch
  sudo pacman -S bubblewrap
  ```

- **Docker** (recommended for production):
  ```bash
  # Ubuntu/Debian
  sudo apt install docker.io

  # Others: https://docs.docker.com/engine/install/
  ```

**Note:** Autobot will fail to start if sandboxing is enabled (`tools.sandbox: auto/bubblewrap/docker`) but no sandbox tool is available.

---

## Quick Start (Local)

Create a new bot in seconds:

```bash
autobot new optimus
cd optimus
```

Install bubblewrap (required for workspace restrictions):
```bash
sudo apt install bubblewrap  # Ubuntu/Debian
```

Edit `.env` and add your API keys:
```bash
vi .env  # Add ANTHROPIC_API_KEY=sk-ant-...
```

Validate and start:
```bash
autobot doctor    # Check for issues (validates sandbox availability)
autobot gateway   # Start gateway
```

✓ **Secure by default**: Kernel-enforced workspace sandbox, localhost binding, .env protection, shell safety.

---

## Multiple Bots (One Machine)

Run multiple isolated bots:

```bash
# Personal bot
autobot new personal-bot
cd personal-bot && autobot gateway --port 18790

# Work bot
cd .. && autobot new work-bot
cd work-bot && autobot gateway --port 18791
```

Each bot has isolated config, workspace, sessions, and logs.

---

## Production Deployment

### Docker (Recommended)

Create `docker-compose.yml`:

```yaml
version: '3.8'

services:
  autobot:
    image: autobot:latest
    container_name: autobot-prod
    user: "1000:1000"
    read_only: true
    security_opt:
      - no-new-privileges:true
    env_file:
      - .env
    volumes:
      - ./config.yml:/app/config.yml:ro
      - autobot-workspace:/app/workspace
      - autobot-sessions:/app/sessions
      # Docker socket (for Docker-in-Docker sandbox)
      - /var/run/docker.sock:/var/run/docker.sock
    tmpfs:
      - /tmp
    ports:
      - "127.0.0.1:18790:18790"
    restart: unless-stopped
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 2G
        reservations:
          cpus: '0.5'
          memory: 512M

volumes:
  autobot-workspace:
  autobot-sessions:
```

**Configuration for Docker deployment:**
```yaml
tools:
  sandbox: "docker"  # Use Docker for sandboxing (auto-detects if not specified)
```

Start:
```bash
docker-compose up -d
docker-compose logs -f autobot
```

**Security enabled**: Non-root user, read-only filesystem, no new privileges, localhost binding, resource limits, Docker-based sandboxing.

---

### Systemd (Linux)

Use the provided service template:

```bash
# Copy service file
sudo cp docs/templates/autobot.service /etc/systemd/system/

# Build and install binary
make release
sudo cp bin/autobot /usr/local/bin/
sudo chmod 755 /usr/local/bin/autobot

# Enable service
sudo systemctl daemon-reload
sudo systemctl enable --now autobot
```

Check status:
```bash
sudo systemctl status autobot
sudo journalctl -u autobot -f
```

**Service includes**: Security hardening (NoNewPrivileges, ProtectSystem), resource limits, automatic restarts.

---

## Configuration Validation

Always validate before deploying:

```bash
autobot doctor          # Check for errors/warnings
autobot doctor --strict # Fail on any warning (CI/CD)
```

### What It Checks

**❌ Errors** (blocks deployment):
- Sandbox enabled but not available
- Plaintext secrets in `config.yml`
- `.env` permissions (must be 0600)
- `.env` inside workspace (exposes secrets)
- No LLM provider configured

**⚠️ Warnings** (review recommended):
- Gateway bound to 0.0.0.0 (network exposure)
- Empty channel allowlists
- Missing `.env` file
- Workspace restrictions disabled

---

## External Access (Optional)

### Reverse Proxy (Nginx)

For external access with TLS, use a reverse proxy. Example configuration in `docs/templates/nginx.conf`:

```bash
# Install nginx
sudo apt install nginx  # Ubuntu/Debian

# Configure proxy (see docs/templates/nginx.conf)
sudo cp docs/templates/nginx.conf /etc/nginx/sites-available/autobot
sudo ln -s /etc/nginx/sites-available/autobot /etc/nginx/sites-enabled/

# Get TLS certificate
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d autobot.example.com

# Enable
sudo nginx -t
sudo systemctl reload nginx
```

**Key features** (from template):
- TLS 1.2+ with strong ciphers
- Security headers (HSTS, X-Frame-Options, CSP)
- WebSocket support
- Request buffering disabled for streaming
- Optional basic auth

---

## Security Best Practices

### 1. Secrets Management

```bash
# .gitignore (auto-created by autobot new)
.env
.env.*
sessions/
logs/
workspace/memory/

# Verify .env permissions
ls -l .env
# Should show: -rw------- (0600)
```

### 2. Workspace Restrictions

```yaml
tools:
  sandbox: auto  # ✓ Default (auto-detect bubblewrap or Docker)
```

### 3. Channel Authorization

```yaml
channels:
  telegram:
    enabled: true
    allow_from: ["123456789"]  # Specific user IDs
    # NEVER: ["*"]             # Allows anyone!
```

### 4. Network Binding

```yaml
gateway:
  host: "127.0.0.1"  # ✓ Default (localhost only)
  # AVOID: "0.0.0.0" # Exposes to all interfaces
```

Use a reverse proxy (nginx) for external access.

### 5. File Permissions

```bash
# Recommended permissions
/var/lib/autobot/         0700 (autobot:autobot)
/var/lib/autobot/.env     0600 (autobot:autobot)
/var/lib/autobot/config.yml 0600 (autobot:autobot)
```

---

## Advanced Setup

### Dedicated User Account (Production)

Create a system user for Autobot:

```bash
# Linux
sudo useradd -r -m -d /var/lib/autobot -s /bin/bash autobot
sudo -u autobot autobot new optimus

# macOS
sudo dscl . -create /Users/autobot
sudo dscl . -create /Users/autobot NFSHomeDirectory /var/lib/autobot
sudo mkdir -p /var/lib/autobot
sudo chown autobot:staff /var/lib/autobot
```

### Resource Limits (Systemd)

Add to `autobot.service`:

```ini
[Service]
CPUQuota=200%      # Max 2 cores
MemoryMax=2G       # Hard limit
MemoryHigh=1.5G    # Soft limit
LimitNOFILE=65536  # File descriptors
TasksMax=512       # Max processes
```

### Backup

Essential files to backup:
```bash
/var/lib/autobot/.env
/var/lib/autobot/config.yml
/var/lib/autobot/sessions/
```

Simple backup script:
```bash
#!/bin/bash
BACKUP_DIR="/backup/autobot/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"
tar czf "$BACKUP_DIR/autobot-backup.tar.gz" \
  -C /var/lib/autobot \
  .env config.yml sessions/
```

---

## Troubleshooting

### Config validation fails
```bash
autobot doctor  # Shows specific errors and fixes
```

### Gateway won't start
```bash
autobot doctor --strict  # Check for warnings
sudo systemctl status autobot  # If using systemd
sudo journalctl -u autobot -f  # View logs
```

### Secrets not loading
```bash
# Verify .env exists and has correct permissions
ls -la .env
chmod 600 .env

# Check environment variable syntax in config.yml
grep ANTHROPIC_API_KEY config.yml
# Should show: api_key: "${ANTHROPIC_API_KEY}"
```

### Permission denied
```bash
# Verify ownership (if using dedicated user)
ls -la /var/lib/autobot/
sudo chown -R autobot:autobot /var/lib/autobot
```

### Nginx 502 Bad Gateway
```bash
# Check if autobot is running
sudo systemctl status autobot
curl http://127.0.0.1:18790/health

# Check nginx logs
sudo tail -f /var/log/nginx/autobot_error.log
```

---

## Quick Reference

### Commands
```bash
autobot new optimus              # Create new bot
autobot doctor                   # Validate config
autobot doctor --strict          # Strict validation
autobot gateway                  # Start gateway
autobot gateway --port 8080      # Custom port
```

### Files
- `.env` - Secrets (never commit, 0600)
- `config.yml` - Configuration (uses ${ENV_VARS})
- `workspace/` - Sandboxed LLM workspace
- `sessions/` - Conversation history
- `docs/templates/` - Production templates (systemd, nginx, docker)

### Security Defaults
- ✓ Workspace sandbox enabled
- ✓ .env files blocked from LLM
- ✓ Symlink operations blocked
- ✓ Localhost-only binding
- ✓ Destructive commands blocked
- ✓ File permissions enforced
- ✓ Validation on startup

---

## Production Checklist

Before deploying to production:

- [ ] `autobot doctor --strict` passes
- [ ] Dedicated user account (not root)
- [ ] .env file permissions (0600)
- [ ] .env not in workspace directory
- [ ] TLS configured (Let's Encrypt)
- [ ] Gateway bound to localhost
- [ ] Nginx reverse proxy (if external access)
- [ ] Resource limits configured
- [ ] Backup script setup
- [ ] Log monitoring enabled
- [ ] Firewall rules configured

---

## Learn More

- [Security](./security.md) - Security model and threat mitigations
- [Configuration](./configuration.md) - Full configuration reference
- [Architecture](./architecture.md) - System design and components
