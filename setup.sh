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
# Install Node.js (v18 LTS - required by Soketi/uWebSockets.js)
# -------------------------
echo "⬆️ Installing Node.js 18 (required by Soketi/uWebSockets.js)..."
sudo npm install -g n || sudo apt-get install -y npm && sudo npm install -g n
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
# Run database setup
# -------------------------
echo "🗄️ Running setup.sql..."
PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f "$SCRIPT_DIR/setup.sql"

echo "🔑 Inserting default app credentials..."
PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "
INSERT INTO websocket_apps (id, key, secret, max_connections, enable_client_messages, enabled, max_backend_events_per_sec, max_client_events_per_sec, max_read_req_per_sec, max_presence_members_per_channel, max_presence_member_size_in_kb, max_channel_name_length, max_event_channels_at_once, max_event_name_length, max_event_payload_in_kb, max_event_batch_size, webhooks, enable_user_authentication)
VALUES ('$APP_ID', '$APP_KEY', '$APP_SECRET', 200, 0, 1, 100, 100, 100, 100, 10, 100, 100, 200, 100, 10, '[]', 0)
ON CONFLICT (id) DO NOTHING;
"

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
