# Fuze Store Cloud Server

## Overview

This repository contains the cloud server setup for Fuze Store, featuring a real-time WebSocket server powered by [Soketi](https://soketi.app/). It is designed to provide scalable, low-latency WebSocket communication for applications such as e-commerce, chat, notifications, and more. The setup includes Docker Compose for containerized deployment, a PostgreSQL-backed app management option, and scripts for easy installation and configuration on Ubuntu servers.

## Features

- **Soketi WebSocket Server**: High-performance, Pusher-compatible WebSocket server.
- **Docker Compose Support**: Easily run the stack locally or in production using Docker.
- **PostgreSQL Integration**: (Optional) Store app credentials and configuration in a PostgreSQL database.
- **Automated Setup Script**: `setup.sh` for one-command installation and configuration on Ubuntu.
- **Nginx Reverse Proxy**: Secure and expose Soketi via your domain with SSL (Let's Encrypt).

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/Fuze-Store/fuze-store-cloud-server.git
cd fuze-store-cloud-server
```

### 2. Running with Docker Compose (Recommended for Local Development)

1. **Edit Environment Variables**: Update credentials and settings in `docker-compose.yml` as needed.
2. **Start the Services**:

   ```bash
   docker-compose up -d
   ```

3. **Access Soketi**: The WebSocket server will be available at `ws://localhost:6001`.

### 3. Manual Installation on Ubuntu (Production)

1. **Edit `setup.sh`**: Fill in the required variables at the top of the script (domain, database credentials, app keys, etc.).
2. **Run the Script**:

   ```bash
   chmod +x setup.sh
   ./setup.sh
   ```

3. **Access Your Server**: Visit `https://your-domain.com` after setup completes.

### 4. Database Setup (PostgreSQL)

If using PostgreSQL for app management, run the SQL in `setup.sql` on your database:

```sql
-- In your PostgreSQL client
\i setup.sql
```

### 5. Nginx & SSL

- Nginx is configured as a reverse proxy for Soketi.
- SSL certificates are automatically provisioned via Let's Encrypt (Certbot) in the setup script.

## Configuration Files

- **docker-compose.yml**: Defines the Docker services and environment variables.
- **setup.sh**: Bash script for automated server setup on Ubuntu.
- **setup.sql**: SQL schema for the `websocket_apps` table (PostgreSQL).
- **soketi.json**: (Optional) Additional Soketi configuration.

## Useful Commands

- Start services: `docker-compose up -d`
- Stop services: `docker-compose down`
- Check Soketi status (systemd): `sudo systemctl status soketi.service`
- View logs: `sudo journalctl -u soketi.service -f`

## Troubleshooting

- Ensure all environment variables are set correctly before running the setup script.
- If using Docker, make sure ports are not in use and Docker is installed.
- For SSL issues, check your domain's DNS and firewall settings.

## Resources

- [Soketi Documentation](https://docs.soketi.app/)
- [Docker Documentation](https://docs.docker.com/)
- [Let's Encrypt / Certbot](https://certbot.eff.org/)

## License

This project is intended for internal use. Please review and update the license as appropriate for your organization.
