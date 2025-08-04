#!/bin/bash
# setup.sh - Net-Insight-Monitor Unified Setup
# - Interactive selection for Development vs. Production environments.
# - Auto-generates an initial API key on fresh installs.
# - Preserves data during migration and self-heals database schema.

# --- Configuration ---
APP_SERVICE_NAME="net_insight_app"
NGINX_SERVICE_NAME="net_insight_nginx"
HOST_DATA_ROOT="/srv/net_insight_monitor/data"
HOST_OPT_SLA_MONITOR_DIR="${HOST_DATA_ROOT}/app_data"
HOST_API_LOGS_DIR="${HOST_DATA_ROOT}/api_logs"
HOST_APACHE_LOGS_DIR="${HOST_DATA_ROOT}/apache_logs"
HOST_CERTBOT_WEBROOT_DIR="${HOST_DATA_ROOT}/certbot-webroot"
DOCKER_COMPOSE_FILE_NAME="docker-compose.yml"
DOCKERFILE_NAME="Dockerfile"
APACHE_CONFIG_DIR="docker/apache"
SQLITE_DB_FILE_NAME="net_insight_monitor.sqlite"
SQLITE_DB_FILE_HOST_PATH="${HOST_OPT_SLA_MONITOR_DIR}/${SQLITE_DB_FILE_NAME}"

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }

# --- Main Setup Logic ---
clear
print_info "Starting Net-Insight Monitor Server Setup..."
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- NEW: Step 0: Choose Environment ---
print_info "Select the deployment environment:"
select DEPLOY_ENV in "Development (HTTP only, no domain needed)" "Production (HTTPS with Nginx & Let's Encrypt)"; do
    case $DEPLOY_ENV in
        "Development (HTTP only, no domain needed)")
            ENV_MODE="DEV"; print_info "Selected DEVELOPMENT mode."; break
            ;;
        "Production (HTTPS with Nginx & Let's Encrypt)")
            ENV_MODE="PROD"; print_info "Selected PRODUCTION mode."; break
            ;;
    esac
done

# --- Detect Mode (Fresh Install vs. Migration) ---
MIGRATION_MODE=false
if [ -d "${HOST_DATA_ROOT}" ]; then
    print_warn "Existing data found at ${HOST_DATA_ROOT}. Entering MIGRATION mode. Your data will be preserved."
    MIGRATION_MODE=true
else
    print_info "No existing data found. Proceeding with a FRESH INSTALLATION."
fi

# --- Step 1: Gather User Input (if Production) ---
if [ "$ENV_MODE" == "PROD" ]; then
    print_info "Production mode requires a domain name and email for SSL certificates."
    read -p "Enter the domain name pointing to this server (e.g., monitor.yourcompany.com): " DOMAIN_NAME
    if [ -z "$DOMAIN_NAME" ]; then print_error "Domain name cannot be empty. Aborting."; exit 1; fi
    read -p "Enter your email for Let's Encrypt renewal notices: " EMAIL_ADDRESS
    if [ -z "$EMAIL_ADDRESS" ]; then print_error "Email address cannot be empty. Aborting."; exit 1; fi
fi

# --- Step 2: Install System Dependencies ---
print_info "Updating package lists and checking dependencies..."
sudo apt-get update -y || { print_error "Apt update failed."; exit 1; }
if ! command -v docker &> /dev/null; then print_info "Installing Docker..."; sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common jq && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - && sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y && sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io || { print_error "Docker installation failed"; exit 1; }; sudo systemctl start docker && sudo systemctl enable docker; else print_info "Docker is already installed."; fi
if ! command -v docker-compose &> /dev/null; then print_info "Installing Docker Compose..."; LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name); [ -z "$LATEST_COMPOSE_VERSION" ] && LATEST_COMPOSE_VERSION="v2.24.6"; sudo curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose || { print_error "Docker Compose download failed"; exit 1; }; else print_info "Docker Compose is already installed."; fi
if ! command -v certbot &> /dev/null || ! command -v sqlite3 &> /dev/null || ! command -v openssl &> /dev/null; then print_info "Installing Certbot, SQLite3, and OpenSSL..."; sudo apt-get install -y certbot sqlite3 openssl; else print_info "Certbot, SQLite3, and OpenSSL are already installed."; fi

# --- Step 3: Create Directories and Build-time Configurations ---
print_info "Creating host directories and Docker configurations..."
sudo mkdir -p "${HOST_OPT_SLA_MONITOR_DIR}" "${HOST_API_LOGS_DIR}" "${HOST_APACHE_LOGS_DIR}"
sudo touch "${HOST_API_LOGS_DIR}/api.log"
mkdir -p "${APACHE_CONFIG_DIR}"

tee "./${DOCKERFILE_NAME}" > /dev/null <<'EOF_DOCKERFILE'
FROM php:8.2-apache
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev libzip-dev zlib1g-dev sqlite3 curl jq bc git iputils-ping dnsutils iproute2 net-tools && \
    docker-php-ext-install -j$(nproc) pdo pdo_sqlite zip && \
    a2enmod rewrite && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY ./docker/apache/000-default.conf /etc/apache2/sites-available/000-default.conf
WORKDIR /var/www/html
COPY ./app/ .
RUN chown -R www-data:www-data /var/www/html && chmod -R 755 /var/www/html
EXPOSE 80
EOF_DOCKERFILE

tee "./${APACHE_CONFIG_DIR}/000-default.conf" > /dev/null <<'EOF_APACHE_CONF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF_APACHE_CONF

# --- Step 4: Database & Permissions (with API Key generation) ---
if [ "${MIGRATION_MODE}" = false ]; then
    print_info "Initializing database schema for new installation..."
    sudo touch "${SQLITE_DB_FILE_HOST_PATH}"
    sudo sqlite3 "${SQLITE_DB_FILE_HOST_PATH}" "
        PRAGMA journal_mode=WAL;
        CREATE TABLE isp_profiles (id INTEGER PRIMARY KEY AUTOINCREMENT, agent_name TEXT NOT NULL, agent_identifier TEXT NOT NULL UNIQUE, api_key TEXT UNIQUE, last_heard_from TEXT, last_reported_hostname TEXT, last_reported_source_ip TEXT, agent_type TEXT, is_active INTEGER DEFAULT 1);
        CREATE TABLE sla_metrics (id INTEGER PRIMARY KEY AUTOINCREMENT, isp_profile_id INTEGER NOT NULL, timestamp TEXT NOT NULL, overall_connectivity TEXT, avg_rtt_ms REAL, avg_loss_percent REAL, avg_jitter_ms REAL, dns_status TEXT, dns_resolve_time_ms INTEGER, http_status TEXT, http_response_code INTEGER, http_total_time_s REAL, speedtest_status TEXT, speedtest_download_mbps REAL, speedtest_upload_mbps REAL, speedtest_ping_ms REAL, speedtest_jitter_ms REAL, wifi_signal_percent INTEGER, wifi_signal_dbm INTEGER, detailed_health_summary TEXT, sla_met_interval INTEGER, FOREIGN KEY (isp_profile_id) REFERENCES isp_profiles(id), UNIQUE(isp_profile_id, timestamp));
        CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
        CREATE INDEX IF NOT EXISTS idx_isp_profiles_agent_identifier ON isp_profiles (agent_identifier);
    "
    print_info "Generating a secure API key for the first agent..."
    FIRST_AGENT_API_KEY=$(openssl rand -base64 32)
    sudo sqlite3 "${SQLITE_DB_FILE_HOST_PATH}" "INSERT INTO isp_profiles (agent_name, agent_identifier, api_key, agent_type, is_active) VALUES ('Default First Agent', 'default-first-agent', '${FIRST_AGENT_API_KEY}', 'Client', 1);"
    echo
    print_success "==================== FIRST AGENT API KEY ===================="
    print_success "Copy this key. You will need it to set up your first agent."
    print_warn "API Key: ${FIRST_AGENT_API_KEY}"
    print_success "==========================================================="
    echo
    read -p "Press [Enter] to continue after you have saved the key..."
else
    print_info "Existing database found. Performing data-preserving migration..."
    # Self-heal schema by adding new columns if they don't exist. Errors are ignored if columns are present.
    sudo sqlite3 "${SQLITE_DB_FILE_HOST_PATH}" "ALTER TABLE isp_profiles ADD COLUMN api_key TEXT;" >/dev/null 2>&1
    sudo sqlite3 "${SQLITE_DB_FILE_HOST_PATH}" "ALTER TABLE sla_metrics ADD COLUMN wifi_signal_percent INTEGER;" >/dev/null 2>&1
    sudo sqlite3 "${SQLITE_DB_FILE_HOST_PATH}" "ALTER TABLE sla_metrics ADD COLUMN wifi_signal_dbm INTEGER;" >/dev/null 2>&1
    print_info "Database schema checked and updated."
fi

print_info "Setting final data permissions..."
sudo chown -R root:www-data "${HOST_DATA_ROOT}"; sudo chmod -R 770 "${HOST_DATA_ROOT}"; sudo chmod 660 "${HOST_API_LOGS_DIR}/api.log"; sudo chmod 660 "${SQLITE_DB_FILE_HOST_PATH}"

# --- Step 5: Stop any old containers ---
if [ "$(docker ps -q -f name=^/${APP_SERVICE_NAME}$)" ] || [ "$(docker ps -q -f name=^/${NGINX_SERVICE_NAME}$)" ]; then
    print_info "Stopping any old running containers..."
    sudo docker-compose down --remove-orphans >/dev/null 2>&1
    print_info "Old containers stopped."
fi

# --- Step 6: Final Configuration and Launch ---
if [ "$ENV_MODE" == "PROD" ]; then
    print_info "Starting PRODUCTION launch..."
    sudo mkdir -p "${HOST_CERTBOT_WEBROOT_DIR}"; mkdir -p "nginx/conf"
    tee "./${DOCKER_COMPOSE_FILE_NAME}" > /dev/null <<EOF
version: '3.8'
services:
  ${APP_SERVICE_NAME}: {build: {context: ., dockerfile: ${DOCKERFILE_NAME}}, container_name: ${APP_SERVICE_NAME}, restart: unless-stopped, volumes: ["${HOST_OPT_SLA_MONITOR_DIR}:/opt/sla_monitor/app_data", "${HOST_API_LOGS_DIR}/api.log:/var/log/api.log", "${HOST_APACHE_LOGS_DIR}:/var/log/apache2"], environment: {APACHE_LOG_DIR: /var/log/apache2}, networks: [net-insight-net]}
  ${NGINX_SERVICE_NAME}: {image: nginx:latest, container_name: ${NGINX_SERVICE_NAME}, restart: unless-stopped, ports: ["80:80", "443:443"], volumes: ["./nginx/conf:/etc/nginx/conf.d", "/etc/letsencrypt:/etc/letsencrypt:ro", "${HOST_CERTBOT_WEBROOT_DIR}:/var/www/certbot"], depends_on: [${APP_SERVICE_NAME}], networks: [net-insight-net]}
networks: {net-insight-net: {driver: bridge}}
EOF
    tee "./nginx/conf/default.conf" > /dev/null <<EOF
server { listen 80; server_name ${DOMAIN_NAME}; location /.well-known/acme-challenge/ { root /var/www/certbot; } location / { return 404; }}
EOF
    sudo docker-compose up -d ${NGINX_SERVICE_NAME}; if [ $? -ne 0 ]; then print_error "Failed to start temporary Nginx."; sudo docker-compose down; exit 1; fi
    sudo certbot certonly --webroot -w "${HOST_CERTBOT_WEBROOT_DIR}" -d "${DOMAIN_NAME}" --email "${EMAIL_ADDRESS}" --agree-tos --no-eff-email --force-renewal; if [ $? -ne 0 ]; then print_error "Certbot failed. Check DNS/firewall."; sudo docker-compose down; exit 1; fi
    sudo docker-compose down
    if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then sudo curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf -o /etc/letsencrypt/options-ssl-nginx.conf; fi
    if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then sudo openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048; fi
    tee "./nginx/conf/default.conf" > /dev/null <<EOF
server { listen 80; server_name ${DOMAIN_NAME}; location /.well-known/acme-challenge/ { root /var/www/certbot; } location / { return 301 https://\$host\$request_uri; } }
server { listen 443 ssl http2; server_name ${DOMAIN_NAME}; ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem; ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem; include /etc/letsencrypt/options-ssl-nginx.conf; ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; location / { proxy_pass http://${APP_SERVICE_NAME}:80; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; }}
EOF
    print_info "Building and starting PRODUCTION stack..."; sudo docker-compose up --build -d
    if [ $? -eq 0 ]; then print_success "PRODUCTION Deployment complete! Dashboard: https://${DOMAIN_NAME}"; else print_error "Failed to start Docker stack."; exit 1; fi
elif [ "$ENV_MODE" == "DEV" ]; then
    print_info "Starting DEVELOPMENT launch..."
    tee "./${DOCKER_COMPOSE_FILE_NAME}" > /dev/null <<EOF
version: '3.8'
services:
  ${APP_SERVICE_NAME}: {build: {context: ., dockerfile: ${DOCKERFILE_NAME}}, container_name: ${APP_SERVICE_NAME}, restart: unless-stopped, ports: ["8080:80"], volumes: ["${HOST_OPT_SLA_MONITOR_DIR}:/opt/sla_monitor/app_data", "${HOST_API_LOGS_DIR}/api.log:/var/log/api.log", "${HOST_APACHE_LOGS_DIR}:/var/log/apache2"], environment: {APACHE_LOG_DIR: /var/log/apache2}}
EOF
    print_info "Building and starting DEVELOPMENT stack..."; sudo docker-compose up --build -d
    if [ $? -eq 0 ]; then SERVER_IP=$(hostname -I | awk '{print $1}'); print_success "DEVELOPMENT Deployment complete! Dashboard: http://${SERVER_IP}:8080"; else print_error "Failed to start Docker stack."; exit 1; fi
fi

echo; sudo docker-compose ps
print_info "--------------------------------------------------------------------"
print_warn "ACTION REQUIRED: To create a web admin user, you must now:"
print_warn "1. Place the 'create_admin_user.php' file into the 'central_server_package/app/' directory."
print_warn "2. Access https://<your_domain>/create_admin_user.php (or http://<ip>:8080/... for dev)."
print_warn "3. DELETE the 'create_admin_user.php' file from the server immediately afterward."
print_info "--------------------------------------------------------------------"