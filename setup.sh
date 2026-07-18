#!/bin/bash

# Exit on any error
set -e

# -------------------------
# Load environment variables from .env
# -------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
  echo "✅ Loaded .env from $SCRIPT_DIR/.env"
else
  echo "❌ .env file not found at $SCRIPT_DIR/.env"
  echo "   Copy .env.example to .env and fill in your values:"
  echo "   cp .env.example .env"
  exit 1
fi

# -------------------------
# Variables - Override in .env
# -------------------------
REPO_NAME="${REPO_NAME:-fuze-store-cloud-server}"
DOMAIN="${DOMAIN:-socket.dev.fuze-store.com}"
PORT="${SOKETI_PORT:-6001}"
DB_HOST="${SOKETI_DB_POSTGRES_HOST}"
DB_PORT="${SOKETI_DB_POSTGRES_PORT}"
DB_USER="${SOKETI_DB_POSTGRES_USERNAME}"
DB_PASS="${SOKETI_DB_POSTGRES_PASSWORD}"
DB_NAME="${SOKETI_DB_POSTGRES_DATABASE}"
DB_TABLE="${SOKETI_APP_MANAGER_POSTGRES_TABLE:-websocket_apps}"
DB_VERSION="${SOKETI_APP_MANAGER_POSTGRES_VERSION}"
APP_ID="${SOKETI_APP_ID:-fuze-store-app-id}"
APP_KEY="${SOKETI_APP_KEY:-fuze-store-app-key}"
APP_SECRET="${SOKETI_APP_SECRET:-fuze-store-app-secret}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin@$DOMAIN}"
SOKETI_USER="${SOKETI_USER:-ubuntu}"
INSTALL_DIR="${INSTALL_DIR:-/home/$SOKETI_USER/$REPO_NAME}"

# WebSocket capacity — env-driven with generous headroom, NOT tied to a fixed store count.
# -1 = unlimited (bounded only by the box's RAM + file descriptors / LimitNOFILE=65535 in the unit).
# Scale by resizing the instance (t4g.small -> t4g.medium), not by editing a hardcoded number.
APP_MAX_CONNECTIONS="${SOKETI_APP_MAX_CONNECTIONS:--1}"
APP_MAX_BACKEND_EVENTS="${SOKETI_APP_MAX_BACKEND_EVENTS_PER_SEC:--1}"
APP_MAX_CLIENT_EVENTS="${SOKETI_APP_MAX_CLIENT_EVENTS_PER_SEC:--1}"
APP_MAX_READ_REQ="${SOKETI_APP_MAX_READ_REQ_PER_SEC:--1}"

# Log retention (days) for journald + nginx logrotate on this box.
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-14}"

# -------------------------
# Refuse to provision a PROD box with the shipped default broadcast secrets.
# A public Soketi with a known secret is an open relay for broadcasts.
# -------------------------
case "$DOMAIN" in
  *dev*|*localhost*|*test*|*staging*) : ;; # non-prod domains may keep defaults
  *)
    if [ "$APP_ID" = "fuze-store-app-id" ] || [ "$APP_KEY" = "fuze-store-app-key" ] || [ "$APP_SECRET" = "fuze-store-app-secret" ]; then
      echo "❌ Refusing to run on prod domain '$DOMAIN' with default Soketi app credentials."
      echo "   Set unique SOKETI_APP_ID / SOKETI_APP_KEY / SOKETI_APP_SECRET in .env first."
      exit 1
    fi
    ;;
esac

# -------------------------
# Ensure swap exists (a 2 GB box can OOM building native uWebSockets.js)
# -------------------------
if ! sudo swapon --show | grep -q '/swapfile'; then
  echo "💾 Creating 2G swapfile..."
  sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# -------------------------
# Update system and install dependencies
# -------------------------
echo "📦 Updating system and installing dependencies..."
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y \
    curl git unzip ufw build-essential software-properties-common \
    postgresql-client nginx certbot python3-certbot-nginx supervisor

# -------------------------
# Install Node.js (v18 LTS - the ONLY version supported by Soketi/uWebSockets.js — do NOT bump)
# -------------------------
echo "⬆️ Installing Node.js 18 (required by Soketi/uWebSockets.js)..."
if ! command -v n >/dev/null 2>&1; then
  sudo apt-get install -y npm
  sudo npm install -g n
fi
sudo n 18
hash -r

# -------------------------
# Create a dedicated user for Soketi
# -------------------------
echo "👤 Creating Soketi user..."
sudo useradd -m -s /bin/bash $SOKETI_USER || true
sudo mkdir -p $INSTALL_DIR
sudo chown $SOKETI_USER:$SOKETI_USER $INSTALL_DIR

# -------------------------
# Run database setup — postgres app manager ONLY. The standard EC2 deployment
# uses SOKETI_APP_MANAGER_DRIVER=array (credentials served from
# SOKETI_DEFAULT_APP_* env; see .env.example + the 2026-07-16 incident) and
# needs no database.
# -------------------------
if [ "${SOKETI_APP_MANAGER_DRIVER:-array}" = "postgres" ]; then
echo "🗄️ Running setup.sql..."
PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f "$SCRIPT_DIR/setup.sql"

echo "🔑 Upserting app credentials (max_connections=$APP_MAX_CONNECTIONS)..."
PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "
INSERT INTO websocket_apps (id, key, secret, max_connections, enable_client_messages, enabled, max_backend_events_per_sec, max_client_events_per_sec, max_read_req_per_sec, max_presence_members_per_channel, max_presence_member_size_in_kb, max_channel_name_length, max_event_channels_at_once, max_event_name_length, max_event_payload_in_kb, max_event_batch_size, webhooks, enable_user_authentication)
VALUES ('$APP_ID', '$APP_KEY', '$APP_SECRET', $APP_MAX_CONNECTIONS, 0, 1, $APP_MAX_BACKEND_EVENTS, $APP_MAX_CLIENT_EVENTS, $APP_MAX_READ_REQ, 100, 10, 100, 100, 200, 100, 10, '[]', 0)
ON CONFLICT (id) DO UPDATE SET
    max_connections            = EXCLUDED.max_connections,
    max_backend_events_per_sec = EXCLUDED.max_backend_events_per_sec,
    max_client_events_per_sec  = EXCLUDED.max_client_events_per_sec,
    max_read_req_per_sec       = EXCLUDED.max_read_req_per_sec,
    enabled                    = EXCLUDED.enabled;
"
else
  echo "🗄️ App manager driver is '${SOKETI_APP_MANAGER_DRIVER:-array}' — skipping setup.sql (array driver needs no DB)."
fi

# -------------------------
# Install Soketi globally
# -------------------------
echo "🎧 Installing Soketi..."
sudo npm install -g @soketi/soketi

# -------------------------
# Copy .env to install directory
# -------------------------
echo "🛠 Setting up Soketi config..."
sudo cp "$SCRIPT_DIR/.env" $INSTALL_DIR/.env
sudo chown $SOKETI_USER:$SOKETI_USER $INSTALL_DIR/.env
sudo chmod 600 $INSTALL_DIR/.env

# -------------------------
# Create systemd service for Soketi
# -------------------------
echo "🚦 Creating systemd service..."
sudo tee /etc/systemd/system/soketi.service > /dev/null <<EOL
[Unit]
Description=Soketi WebSocket Server
After=network.target

[Service]
Type=simple
User=$SOKETI_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=/usr/bin/soketi start
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable service
sudo systemctl daemon-reload
sudo systemctl enable soketi.service
sudo systemctl start soketi.service

# -------------------------
# Log retention — bound disk usage (${LOG_RETENTION_DAYS} days)
# -------------------------
echo "🧹 Configuring log retention (${LOG_RETENTION_DAYS} days)..."

# journald: Soketi logs here (systemd unit uses StandardOutput=journal). Cap age + total size.
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/retention.conf > /dev/null <<EOL
[Journal]
MaxRetentionSec=${LOG_RETENTION_DAYS}day
SystemMaxUse=500M
EOL
sudo systemctl restart systemd-journald

# nginx access/error logs: daily rotation, keep ${LOG_RETENTION_DAYS} compressed
# (Ubuntu's default is weekly x14 = ~14 weeks — too long for a small root volume).
sudo tee /etc/logrotate.d/fuze-soketi-nginx > /dev/null <<EOL
/var/log/nginx/*.log {
    daily
    rotate ${LOG_RETENTION_DAYS}
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 \$(cat /var/run/nginx.pid)
    endscript
}
EOL

# -------------------------
# Configure UFW firewall
# -------------------------
echo "Configuring firewall..."
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw --force enable

# -------------------------
# Configure Nginx as reverse proxy
# -------------------------
echo "🔧 Configuring Nginx..."
sudo tee /etc/nginx/sites-available/soketi <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Keep long-lived WebSocket connections open (nginx default is 60s, which
        # silently drops idle POS/KDS/CFD sockets).
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    }
}
EOL

sudo ln -sf /etc/nginx/sites-available/soketi /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# -------------------------
# Setup SSL with Certbot
# -------------------------
if sudo test -d "/etc/letsencrypt/live/$DOMAIN"; then
  echo "🔐 SSL certificate already present for $DOMAIN — skipping certbot request."
else
  echo "🔐 Requesting SSL certificate..."
  sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $CERTBOT_EMAIL
fi

# Reload Nginx
sudo systemctl reload nginx

# -------------------------
# Finished
# -------------------------
echo "----------------------------------"
echo "🎉 Setup complete!"
echo "Access your Soketi server at: https://$DOMAIN"
echo "Systemd service: soketi.service"
echo "Soketi runs on port $PORT behind Nginx reverse proxy"
echo "----------------------------------"
