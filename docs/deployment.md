# Deployment Guide

Secure deployment patterns for running Autobot in production.

## Quick Start (Development)

```bash
# Run as your current user (development only)
./bin/autobot gateway
```

⚠️ **Not recommended for production** - uses your user account with full permissions.

---

## Production: Dedicated User (Recommended)

### 1. Create Dedicated User

```bash
# Linux
sudo useradd -r -m -d /var/lib/autobot -s /bin/bash autobot

# macOS
sudo dscl . -create /Users/autobot
sudo dscl . -create /Users/autobot UserShell /bin/bash
sudo dscl . -create /Users/autobot RealName "Autobot Service"
sudo dscl . -create /Users/autobot UniqueID 501
sudo dscl . -create /Users/autobot PrimaryGroupID 20
sudo dscl . -create /Users/autobot NFSHomeDirectory /var/lib/autobot
sudo mkdir -p /var/lib/autobot
sudo chown autobot:staff /var/lib/autobot
```

### 2. Setup Directories

```bash
sudo -u autobot mkdir -p /var/lib/autobot/{.config/autobot,workspace,logs}
sudo chmod 700 /var/lib/autobot/.config/autobot
sudo chmod 700 /var/lib/autobot/workspace
```

### 3. Install Binary

```bash
# Copy binary
sudo cp bin/autobot /usr/local/bin/autobot
sudo chown autobot:autobot /usr/local/bin/autobot
sudo chmod 755 /usr/local/bin/autobot
```

### 4. Create Config

```bash
# Create config as autobot user
sudo -u autobot vi /var/lib/autobot/.config/autobot/config.yml
```

**Minimal production config:**
```yaml
providers:
  anthropic:
    api_key: "${ANTHROPIC_API_KEY}"

agents:
  defaults:
    workspace: "/var/lib/autobot/workspace"

channels:
  telegram:
    enabled: true
    token: "${TELEGRAM_BOT_TOKEN}"
    allow_from: ["@your_username"]  # Allowlist only

tools:
  restrict_to_workspace: true  # Required for security
  exec:
    timeout: 60
    full_shell_access: false   # Required for workspace sandbox

gateway:
  host: "127.0.0.1"  # Localhost only
  port: 18790
```

### 5. Set Environment Variables

```bash
# Create environment file (readable only by autobot user)
sudo -u autobot tee /var/lib/autobot/.env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-your-key-here
TELEGRAM_BOT_TOKEN=your-bot-token-here
EOF

sudo chmod 600 /var/lib/autobot/.env
```

### 6. Test as Autobot User

```bash
# Load env and test
sudo -u autobot bash -c 'source /var/lib/autobot/.env && /usr/local/bin/autobot gateway'
```

---

## Production: Systemd Service (Linux)

### 1. Create Service File

`/etc/systemd/system/autobot.service`:

```ini
[Unit]
Description=Autobot AI Agent
After=network.target

[Service]
Type=simple
User=autobot
Group=autobot
WorkingDirectory=/var/lib/autobot

# Load environment
EnvironmentFile=/var/lib/autobot/.env

# Run gateway
ExecStart=/usr/local/bin/autobot gateway --config /var/lib/autobot/.config/autobot/config.yml

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/autobot
CapabilityBoundingSet=

# Restart on failure
Restart=on-failure
RestartSec=10

# Logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 2. Enable and Start

```bash
sudo systemctl daemon-reload
sudo systemctl enable autobot
sudo systemctl start autobot

# Check status
sudo systemctl status autobot

# View logs
sudo journalctl -u autobot -f
```

---

## Production: Docker (Recommended)

### 1. Build Image

```bash
docker build -t autobot:latest .
```

### 2. Run Container

```bash
docker run -d \
  --name autobot \
  --user 1000:1000 \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  -e TELEGRAM_BOT_TOKEN=... \
  -v $(pwd)/config.yml:/app/config.yml:ro \
  -v autobot-workspace:/app/workspace \
  -v autobot-sessions:/app/sessions \
  --read-only \
  --tmpfs /tmp \
  --security-opt=no-new-privileges \
  -p 127.0.0.1:18790:18790 \
  autobot:latest gateway
```

**Security features:**
- `--user 1000:1000` - Non-root user
- `--read-only` - Immutable filesystem
- `--tmpfs /tmp` - Temporary storage
- `-p 127.0.0.1:18790` - Localhost only
- `--security-opt=no-new-privileges` - Prevent privilege escalation

### 3. Docker Compose

`docker-compose.yml`:

```yaml
version: '3.8'

services:
  autobot:
    image: autobot:latest
    container_name: autobot
    user: "1000:1000"
    read_only: true
    security_opt:
      - no-new-privileges:true
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
    volumes:
      - ./config.yml:/app/config.yml:ro
      - autobot-workspace:/app/workspace
      - autobot-sessions:/app/.config/autobot/sessions
    tmpfs:
      - /tmp
    ports:
      - "127.0.0.1:18790:18790"
    restart: unless-stopped

volumes:
  autobot-workspace:
  autobot-sessions:
```

Run with:
```bash
docker-compose up -d
docker-compose logs -f
```

---

## Production: External Access (Advanced)

If you need external access to the gateway, use a reverse proxy:

### Nginx + TLS

```nginx
upstream autobot {
    server 127.0.0.1:18790;
}

server {
    listen 443 ssl http2;
    server_name autobot.yourdomain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://autobot;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;

        # Add authentication here if needed
        auth_basic "Autobot Gateway";
        auth_basic_user_file /etc/nginx/.htpasswd;
    }
}
```

**Never expose the gateway port directly to the internet!**

---

## Security Checklist

Before production deployment:

- [ ] Dedicated user account (not root, not your personal account)
- [ ] Config/workspace directories: 0700 permissions
- [ ] Environment variables for secrets (not in config files)
- [ ] `restrict_to_workspace: true`
- [ ] `full_shell_access: false`
- [ ] Channel `allow_from` configured (not empty, not ["*"])
- [ ] Gateway bound to localhost (`host: 127.0.0.1`)
- [ ] TLS if external access needed (via reverse proxy)
- [ ] Systemd security hardening or Docker isolation
- [ ] Log monitoring enabled
- [ ] Regular security updates

---

## Permissions Reference

```bash
# Recommended permissions
/var/lib/autobot/                       0700 (autobot:autobot)
/var/lib/autobot/.config/autobot/       0700 (autobot:autobot)
/var/lib/autobot/.config/autobot/*.yml  0600 (autobot:autobot)
/var/lib/autobot/.env                   0600 (autobot:autobot)
/var/lib/autobot/workspace/             0700 (autobot:autobot)
/var/lib/autobot/sessions/              0700 (autobot:autobot)
/usr/local/bin/autobot                  0755 (autobot:autobot)
```

**Verify permissions:**
```bash
sudo ls -la /var/lib/autobot/.config/autobot/
# Should show: drwx------ (700) for directories, -rw------- (600) for files
```
