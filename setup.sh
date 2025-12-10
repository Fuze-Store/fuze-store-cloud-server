#!/bin/bash

# -------------------------
# Production Soketi Setup (No Docker)
# -------------------------

# Exit on any error
set -e

# -------------------------
# Variables - EDIT THESE
# -------------------------
REPO_NAME="fuze-store-cloud-server" # Name of your repository
DOMAIN="socket.dev.fuze-store.com" # Your domain name
PORT="6001" # Port for Soketi to listen on
DB_HOST="fuze-store-dev-db.c5q6y0ascohg.ap-southeast-1.rds.amazonaws.com" 
DB_PORT="3306" 
DB_USER="dbadmin"
DB_PASS="AVNS_IXz7UxZBS1FMs4G84PL"
DB_NAME="fuze"
DB_TABLE="websocket_apps"
DB_VERSION="18.1"
APP_ID="fuze-store-app-id" # Your Soketi App ID
APP_KEY="fuze-store-app-key" # Your Soketi App Key
APP_SECRET="fuze-store-app-secret" # Your Soketi App Secret
SOCKETI_USER="ubuntu"
INSTALL_DIR="/home/ubuntu/$REPO_NAME"  # Full path to your installation directory

# -------------------------
# Update system and install dependencies
# -------------------------
echo "📦 Updating system and installing dependencies..."
sudo apt update -y
sudo apt upgrade -y
sudo apt install -y curl git ufw software-properties-common nginx certbot python3-certbot-nginx build-essential

# -------------------------
# Install Node.js (v18 LTS)
# -------------------------
echo "⬆️ Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# -------------------------
# Create a dedicated user for Soketi
# -------------------------
echo "👤 Creating Soketi user..."
sudo useradd -m -s /bin/bash $SOCKETI_USER || true
sudo mkdir -p $INSTALL_DIR
sudo chown $SOCKETI_USER:$SOCKETI_USER $INSTALL_DIR

# -------------------------
# Install Soketi globally
# -------------------------
echo "🎧 Installing Soketi..."
sudo npm install -g @soketi/soketi

# -------------------------
# Create Soketi config file
# -------------------------
echo "🛠 Creating Soketi config..."
cat > $INSTALL_DIR/soketi.env <<EOL
# Soketi environment configuration

SOKETI_DEBUG=true
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
SOKETI_HOST=0.0.0.0
SOKETI_PORT=$PORT
SOKETI_SHUTDOWN_GRACE_PERIOD=10000
EOL

sudo chown $SOCKETI_USER:$SOCKETI_USER $INSTALL_DIR/soketi.env

# -------------------------
# Create systemd service for Soketi
# -------------------------
echo "🚦 Creating systemd service..."
cat > /etc/systemd/system/soketi.service <<EOL
[Unit]
Description=Soketi WebSocket Server
After=network.target

[Service]
Type=simple
User=$SOCKETI_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/soketi.env
ExecStart=/usr/bin/soketi start
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
sudo ufw enable

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
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

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
