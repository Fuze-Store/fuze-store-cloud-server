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
# Install Node.js (v20 LTS)
# -------------------------
echo "⬆️ Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# -------------------------
# Create a dedicated user for Soketi
# -------------------------
echo "👤 Creating Soketi user..."
sudo useradd -m -s /bin/bash $SOKETI_USER || true
sudo mkdir -p $INSTALL_DIR
sudo chown $SOKETI_USER:$SOKETI_USER $INSTALL_DIR

# -------------------------
# Install Soketi globally
# -------------------------
echo "🎧 Installing Soketi..."
sudo npm install -g @soketi/soketi

# -------------------------
# Create Soketi config file
# -------------------------
echo "🛠 Creating Soketi config..."
sudo tee $INSTALL_DIR/soketi.env > /dev/null <<EOL
# Soketi environment configuration

SOKETI_DEBUG=false
SOKETI_APP_MANAGER_DRIVER=postgres
SOKETI_DB_POSTGRES_HOST=$DB_HOST
SOKETI_DB_POSTGRES_PORT=$DB_PORT
SOKETI_DB_POSTGRES_USERNAME=$DB_USER
SOKETI_DB_POSTGRES_PASSWORD=$DB_PASS
SOKETI_DB_POSTGRES_DATABASE=$DB_NAME
SOKETI_APP_MANAGER_POSTGRES_TABLE=$DB_TABLE
SOKETI_APP_MANAGER_POSTGRES_VERSION=$DB_VERSION
SOKETI_APP_MANAGER_CACHE_ENABLED=true
SOKETI_APP_MANAGER_CACHE_TTL=-1

SOKETI_RATE_LIMITER_DRIVER=local

SOKETI_HTTP_MAX_REQUEST_SIZE=100
SOKETI_EVENT_MAX_CHANNELS_AT_ONCE=100
SOKETI_EVENT_MAX_NAME_LENGTH=200
SOKETI_EVENT_MAX_SIZE_IN_KB=100
SOKETI_EVENT_MAX_BATCH_SIZE=10
SOKETI_CHANNEL_MAX_NAME_LENGTH=100
SOKETI_PRESENCE_MAX_MEMBER_SIZE=10
SOKETI_PRESENCE_MAX_MEMBERS=100

SOKETI_WEBHOOKS_BATCHING=1
SOKETI_WEBHOOKS_BATCHING_DURATION=1000

SOKETI_DEFAULT_APP_ID=$APP_ID
SOKETI_DEFAULT_APP_KEY=$APP_KEY
SOKETI_DEFAULT_APP_SECRET=$APP_SECRET
SOKETI_APP_KEY=$APP_KEY
SOKETI_APP_ID=$APP_ID
SOKETI_APP_SECRET=$APP_SECRET
SOKETI_HOST=127.0.0.1
SOKETI_PORT=$PORT
SOKETI_SHUTDOWN_GRACE_PERIOD=10000
EOL

sudo chown $SOKETI_USER:$SOKETI_USER $INSTALL_DIR/soketi.env
sudo chmod 600 $INSTALL_DIR/soketi.env

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
EnvironmentFile=$INSTALL_DIR/soketi.env
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
echo "🔐 Requesting SSL certificate..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $CERTBOT_EMAIL

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
