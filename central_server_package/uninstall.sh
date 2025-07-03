#!/bin/bash
# uninstall.sh - Net-Insight Monitor Server Uninstaller
# This script will completely remove the server application, its data,
# and associated Docker components. It includes safety prompts.

# --- Configuration (Must match setup.sh) ---
APP_SERVICE_NAME="net_insight_app"
NGINX_SERVICE_NAME="net_insight_nginx"
HOST_DATA_ROOT="/srv/net_insight_monitor/data"
NGINX_CONFIG_FILE="./nginx/conf/default.conf"

# --- Helper Functions ---
print_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
print_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }

# --- Main Uninstall Logic ---
clear
print_warn "================================================================"
print_warn "        Net-Insight Monitor Server Uninstaller"
print_warn "================================================================"
print_warn "This script will permanently remove the Net-Insight Monitor server."
echo
if [ "$(id -u)" -ne 0 ]; then print_error "This script must be run with sudo: sudo $0"; exit 1; fi

# --- PRIMARY CONFIRMATION ---
print_warn "This will stop and delete the following Docker components:"
print_warn "  - Containers: ${APP_SERVICE_NAME}, ${NGINX_SERVICE_NAME}"
print_warn "  - All associated Docker images and networks."
echo
read -p "Are you absolutely sure you want to continue? (Type 'YES' to proceed): " CONFIRMATION
if [ "$CONFIRMATION" != "YES" ]; then
    print_error "Uninstallation aborted by user."
    exit 1
fi

# --- Step 1: Stop and Remove Docker Stack ---
print_info "Stopping and removing Docker stack..."
if [ -f ./docker-compose.yml ]; then
    sudo docker-compose down --rmi all -v
    if [ $? -eq 0 ]; then
        print_success "Docker stack completely removed."
    else
        print_error "Failed to remove Docker stack via docker-compose. Attempting manual removal..."
        sudo docker stop ${APP_SERVICE_NAME} ${NGINX_SERVICE_NAME} >/dev/null 2>&1
        sudo docker rm ${APP_SERVICE_NAME} ${NGINX_SERVICE_NAME} >/dev/null 2>&1
    fi
else
    print_warn "docker-compose.yml not found. Attempting to stop/remove containers by name..."
    sudo docker stop ${APP_SERVICE_NAME} ${NGINX_SERVICE_NAME} >/dev/null 2>&1
    sudo docker rm ${APP_SERVICE_NAME} ${NGINX_SERVICE_NAME} >/dev/null 2>&1
    print_success "Manually stopped and removed containers."
fi
echo

# --- Step 2: Remove Host Data Directory ---
if [ -d "${HOST_DATA_ROOT}" ]; then
    print_warn "The application's persistent data is stored at: ${HOST_DATA_ROOT}"
    print_warn "This includes the database, logs, and any uploaded files."
    read -p "Do you want to PERMANENTLY DELETE all this data? (y/N): " DELETE_DATA
    if [[ "$DELETE_DATA" == "y" || "$DELETE_DATA" == "Y" ]]; then
        print_info "Deleting host data directory: ${HOST_DATA_ROOT}"
        sudo rm -rf "${HOST_DATA_ROOT}"
        print_success "Host data directory deleted."
    else
        print_info "Skipping deletion of host data directory. Your data is preserved at ${HOST_DATA_ROOT}"
    fi
else
    print_info "Host data directory not found, skipping."
fi
echo

# --- Step 3: Remove SSL Certificates ---
DOMAIN_NAME=""
if [ -f "$NGINX_CONFIG_FILE" ]; then
    DOMAIN_NAME=$(grep -m 1 "server_name" "$NGINX_CONFIG_FILE" | awk '{print $2}' | sed 's/;//')
fi

if [ -n "$DOMAIN_NAME" ] && command -v certbot &> /dev/null; then
    print_warn "Found SSL certificate for domain: ${DOMAIN_NAME}"
    print_warn "Deleting this may affect other applications on this server if they use the same certificate."
    read -p "Do you want to delete the SSL certificate for ${DOMAIN_NAME}? (y/N): " DELETE_CERT
    if [[ "$DELETE_CERT" == "y" || "$DELETE_CERT" == "Y" ]]; then
        print_info "Deleting certificate for ${DOMAIN_NAME}..."
        sudo certbot delete --cert-name "${DOMAIN_NAME}"
        print_success "Certificate deleted."
    else
        print_info "Skipping SSL certificate deletion."
    fi
else
    print_info "No SSL certificate found in local config, or Certbot is not installed. Skipping."
fi
echo

# --- Step 4: Final Instructions ---
print_success "Core uninstallation process is complete."
print_info "If you wish to remove the project files themselves, you can now safely run:"
print_info "  rm -rf ../Net-Insight-Monitor"
echo