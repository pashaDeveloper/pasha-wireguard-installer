#!/usr/bin/env bash
set -Eeuo pipefail

# Public bootstrap installer.
# Safe to put in a public repository: it contains no private key or token.

PRIVATE_REPO_SSH_URL="${PRIVATE_REPO_SSH_URL:-git@github.com:pashaDeveloper/pasha-forever-wireguard-3.git}"
PROJECT_DIR="${PROJECT_DIR:-$HOME/pasha-forever-wireguard-3}"
DEPLOY_KEY_PATH="${DEPLOY_KEY_PATH:-$HOME/.ssh/pasha_forever_wireguard_deploy}"
PANEL_PORT="${PANEL_PORT:-51821}"
PANEL_PORT_END="${PANEL_PORT_END:-$((PANEL_PORT + 100))}"
WG_PORT="${WG_PORT:-51820}"
LANG_VALUE="${LANG_VALUE:-fa}"
PASSWORD_HASH="${PASSWORD_HASH:-\$2a\$12\$1TMRGxEHRqYIgDMhEj1Txe9HOv7FwRY0I5s5YU.v.wziEMwZ2kK8i}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-orebu@tmvaswgcsdlcscaacsafdvgfdbybudc.com}"
ACME_KEY_FILE="${ACME_KEY_FILE:-/p}"
ACME_FULLCHAIN_FILE="${ACME_FULLCHAIN_FILE:-/c}"
REMOVE_PROJECT_AFTER_INSTALL="${REMOVE_PROJECT_AFTER_INSTALL:-yes}"
NGINX_SITE_NAME="${NGINX_SITE_NAME:-pasha-panel}"
NGINX_AVAILABLE_DIR="${NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
NGINX_SITE_FILE="${NGINX_SITE_FILE:-$NGINX_AVAILABLE_DIR/$NGINX_SITE_NAME.conf}"
NGINX_ENABLED_FILE="${NGINX_ENABLED_FILE:-$NGINX_ENABLED_DIR/$NGINX_SITE_NAME.conf}"
PANEL_CERT_ENABLED=0
NGINX_WAS_ACTIVE=0
RED=$'\033[31m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

need_command() {
  command -v "$1" >/dev/null 2>&1
}

run_sudo() {
  if [ -n "$SUDO" ]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

is_ipv4_address() {
  printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'
}

is_domain_name() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
}

detect_server_ip() {
  local ip=""

  if need_command curl; then
    ip="$(curl -4fsS https://api.ipify.org || true)"
    if [ -z "$ip" ]; then
      ip="$(curl -4fsS https://ifconfig.me || true)"
    fi
  fi

  if [ -z "$ip" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  printf '%s' "$ip"
}

install_base_packages() {
  if ! need_command apt-get; then
    echo "This installer expects an Ubuntu/Debian server with apt-get." >&2
    exit 1
  fi

  $SUDO apt-get update
  $SUDO apt-get install -y ca-certificates curl git openssh-client openssl socat
}

install_ssl_packages() {
  install_base_packages
  $SUDO apt-get install -y nginx
}

choose_panel_host() {
  local detected_host="$1"
  local panel_domain="$PANEL_DOMAIN"

  echo >&2
  if [ -z "$panel_domain" ]; then
    echo "Enter panel domain for WG_HOST/SSL, or press Enter to use detected IP ($detected_host):"
    printf '> '
    read -r panel_domain
  fi

  if [ -n "$panel_domain" ]; then
    if ! is_domain_name "$panel_domain"; then
      echo "Invalid domain: $panel_domain" >&2
      echo "Use a real domain like panel.example.com, without http:// or https://." >&2
      exit 1
    fi
    printf '%s' "$panel_domain"
  else
    printf '%s' "$detected_host"
  fi
}

choose_certificate_domain() {
  local panel_domain="$PANEL_DOMAIN"

  echo >&2
  if [ -z "$panel_domain" ]; then
    echo "Enter panel domain for SSL (example: panel.example.com):"
    printf '> '
    read -r panel_domain
  fi

  if [ -z "$panel_domain" ]; then
    echo "ERROR: Domain is required for SSL certificate." >&2
    exit 1
  fi

  if is_ipv4_address "$panel_domain"; then
    echo "ERROR: Let's Encrypt certificates require a domain, not an IP address." >&2
    exit 1
  fi

  if ! is_domain_name "$panel_domain"; then
    echo "Invalid domain: $panel_domain" >&2
    echo "Use a real domain like panel.example.com, without http:// or https://." >&2
    exit 1
  fi

  printf '%s' "$panel_domain"
}

run_acme_step() {
  local description="$1"
  shift

  echo
  echo "$description"
  if ! "$@"; then
    echo
    echo "ERROR: $description failed." >&2
    echo "Check that the domain DNS A record points to this server and that TCP port 80 is open." >&2
    exit 1
  fi
}

run_acme_issue_step() {
  local panel_host="$1"
  local acme_sh="$2"

  echo
  echo "Issuing certificate for $panel_host"
  if "$acme_sh" --issue -d "$panel_host" --standalone; then
    return 0
  fi

  if "$acme_sh" --list | grep -qE "(^|[[:space:]])${panel_host}([[:space:]]|$)"; then
    echo
    echo "Certificate for $panel_host already exists and is not due for renewal."
    echo "Continuing with certificate file installation."
    return 0
  fi

  echo
  echo "ERROR: Issuing certificate for $panel_host failed." >&2
  echo "Check that the domain DNS A record points to this server and that TCP port 80 is open." >&2
  exit 1
}

prepare_certificate_output_paths() {
  local key_dir
  local fullchain_dir

  key_dir="$(dirname "$ACME_KEY_FILE")"
  fullchain_dir="$(dirname "$ACME_FULLCHAIN_FILE")"

  if [ "$key_dir" != "/" ]; then
    run_sudo mkdir -p "$key_dir"
    run_sudo chown "$(id -u):$(id -g)" "$key_dir"
  fi

  if [ "$fullchain_dir" != "/" ] && [ "$fullchain_dir" != "$key_dir" ]; then
    run_sudo mkdir -p "$fullchain_dir"
    run_sudo chown "$(id -u):$(id -g)" "$fullchain_dir"
  fi
}

install_acme_if_needed() {
  if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
    run_acme_step "Installing acme.sh" sh -c "curl -fsSL https://get.acme.sh | sh"
  fi

  if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
    echo "ERROR: acme.sh was not installed at $HOME/.acme.sh/acme.sh" >&2
    exit 1
  fi
}

issue_panel_certificate() {
  local panel_host="$1"
  local use_cert="${PANEL_CERT:-}"
  local acme_sh="$HOME/.acme.sh/acme.sh"

  if is_ipv4_address "$panel_host"; then
    echo
    echo "SSL certificate skipped: Let's Encrypt needs a domain, not an IP address."
    return 0
  fi

  if [ -z "$use_cert" ]; then
    echo
    read -r -p "Issue Let's Encrypt certificate for $panel_host? Type yes to enable SSL cert option: " use_cert
  fi

  if [ "$use_cert" != "yes" ]; then
    return 0
  fi

  PANEL_CERT_ENABLED=1

  if [ -z "$ACME_EMAIL" ]; then
    read -r -p "Enter email for Let's Encrypt account: " ACME_EMAIL
  fi

  if [ -z "$ACME_EMAIL" ]; then
    echo "ERROR: ACME_EMAIL is required for certificate registration." >&2
    exit 1
  fi

  install_acme_if_needed

  run_acme_step "Setting default CA to Let's Encrypt" "$acme_sh" --set-default-ca --server letsencrypt
  run_acme_step "Registering Let's Encrypt account" "$acme_sh" --register-account -m "$ACME_EMAIL"
  run_acme_issue_step "$panel_host" "$acme_sh"

  prepare_certificate_output_paths
  run_acme_step "Installing certificate files" "$acme_sh" --install-cert -d "$panel_host" \
    --key-file "$ACME_KEY_FILE" \
    --fullchain-file "$ACME_FULLCHAIN_FILE"
  $SUDO chmod 600 "$ACME_KEY_FILE"
  $SUDO chmod 644 "$ACME_FULLCHAIN_FILE"

  echo
  echo "Certificate installed:"
  echo "Key: $ACME_KEY_FILE"
  echo "Fullchain: $ACME_FULLCHAIN_FILE"
}

stop_nginx_for_acme() {
  NGINX_WAS_ACTIVE=0

  if need_command systemctl && $SUDO systemctl is-active --quiet nginx; then
    NGINX_WAS_ACTIVE=1
    echo
    echo "Stopping nginx temporarily for standalone certificate issuance..."
    $SUDO systemctl stop nginx
  elif need_command service && $SUDO service nginx status >/dev/null 2>&1; then
    NGINX_WAS_ACTIVE=1
    echo
    echo "Stopping nginx temporarily for standalone certificate issuance..."
    $SUDO service nginx stop
  fi
}

start_nginx_after_acme() {
  if [ "$NGINX_WAS_ACTIVE" -eq 1 ]; then
    echo
    echo "Starting nginx again..."
    if need_command systemctl; then
      $SUDO systemctl start nginx
    else
      $SUDO service nginx start
    fi
  fi
}

configure_nginx_https() {
  local panel_domain="$1"
  local panel_port="${PANEL_PORT:-51821}"

  run_sudo mkdir -p "$NGINX_AVAILABLE_DIR" "$NGINX_ENABLED_DIR"

  run_sudo tee "$NGINX_SITE_FILE" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $panel_domain;

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $panel_domain;

    ssl_certificate $ACME_FULLCHAIN_FILE;
    ssl_certificate_key $ACME_KEY_FILE;

    location / {
        proxy_pass http://127.0.0.1:$panel_port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  run_sudo ln -sfn "$NGINX_SITE_FILE" "$NGINX_ENABLED_FILE"
  run_acme_step "Testing nginx configuration" $SUDO nginx -t

  if need_command systemctl; then
    run_acme_step "Reloading nginx" sh -c "$SUDO systemctl reload nginx || $SUDO systemctl restart nginx"
  else
    run_acme_step "Reloading nginx" sh -c "$SUDO service nginx reload || $SUDO service nginx restart"
  fi
}

ensure_deploy_key() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  if [ ! -f "$DEPLOY_KEY_PATH.pub" ]; then
    ssh-keygen -t ed25519 -C "pasha-forever-wireguard-deploy" -f "$DEPLOY_KEY_PATH" -N ""
  fi

  chmod 600 "$DEPLOY_KEY_PATH"
  chmod 644 "$DEPLOY_KEY_PATH.pub"

  echo
  echo "Add this public key to the PRIVATE repository deploy keys:"
  echo "GitHub repo > Settings > Deploy keys > Add deploy key"
  echo "Write access: OFF"
  echo
  printf '%s%s' "$BOLD" "$RED"
  cat "$DEPLOY_KEY_PATH.pub"
  printf '%s' "$RESET"
  echo

  read -r -p "After adding the deploy key, type yes to continue: " confirmed
  if [ "$confirmed" != "yes" ]; then
    echo "Stopped. Run this installer again after adding the deploy key."
    exit 0
  fi

  ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
  chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true

  if ! grep -q "Host github.com-pasha-forever-wireguard" "$HOME/.ssh/config" 2>/dev/null; then
    {
      echo
      echo "Host github.com-pasha-forever-wireguard"
      echo "  HostName github.com"
      echo "  User git"
      echo "  IdentityFile $DEPLOY_KEY_PATH"
      echo "  IdentitiesOnly yes"
    } >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
  fi

  PRIVATE_REPO_SSH_URL="${PRIVATE_REPO_SSH_URL/git@github.com:/git@github.com-pasha-forever-wireguard:}"
}

ensure_docker() {
  if ! need_command docker; then
    curl -fsSL https://get.docker.com | sh
  fi

  if ! $SUDO docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin was not found after Docker installation." >&2
    exit 1
  fi

  if [ -n "$SUDO" ]; then
    $SUDO usermod -aG docker "$(whoami)" || true
  fi
}

clone_or_update_private_repo() {
  if [ -d "$PROJECT_DIR/.git" ]; then
    git -C "$PROJECT_DIR" pull --ff-only
  else
    git clone "$PRIVATE_REPO_SSH_URL" "$PROJECT_DIR"
  fi
}

write_server_env() {
  local server_host="$1"
  local session_secret

  if [ -z "$server_host" ]; then
    echo "Server IP was not detected. Enter WG_HOST manually:"
    printf '> '
    read -r server_host
  fi

  session_secret="$(openssl rand -hex 32)"

  {
    printf 'WG_HOST=%s\n' "$server_host"
    printf 'LANG_VALUE=%s\n' "$LANG_VALUE"
    printf 'PANEL_PORT=%s\n' "$PANEL_PORT"
    printf 'PANEL_PORT_START=%s\n' "$PANEL_PORT"
    printf 'PANEL_PORT_END=%s\n' "$PANEL_PORT_END"
    printf 'WG_PUBLISHED_PORT=%s\n' "$WG_PORT"
    printf 'WG_CONFIG_PORT=%s\n' "$WG_PORT"
    printf 'SESSION_SECRET=%s\n' "$session_secret"
    printf 'PASSWORD_HASH=%s\n' "$PASSWORD_HASH"
  } > "$PROJECT_DIR/.env"

  chmod 600 "$PROJECT_DIR/.env"
}

open_firewall_ports() {
  if need_command ufw; then
    $SUDO ufw allow "$WG_PORT/udp" || true
    $SUDO ufw allow "$PANEL_PORT/tcp" || true
    if [ "$PANEL_CERT_ENABLED" -eq 1 ]; then
      $SUDO ufw allow 80/tcp || true
      $SUDO ufw allow 443/tcp || true
    fi
  fi
}

start_stack() {
  (cd "$PROJECT_DIR" && $SUDO docker compose --env-file .env up -d --build)
}

cleanup_project_dir_after_install() {
  local project_real=""
  local cwd_real=""

  if [ "$REMOVE_PROJECT_AFTER_INSTALL" != "yes" ]; then
    return 0
  fi

  if [ ! -d "$PROJECT_DIR" ]; then
    return 0
  fi

  project_real="$(cd "$PROJECT_DIR" && pwd -P)"
  cwd_real="$(pwd -P)"

  if [ "$project_real" = "$cwd_real" ]; then
    echo
    echo "Project directory was not removed because the installer is running from it:"
    echo "$project_real"
    return 0
  fi

  echo
  echo "Removing downloaded project directory:"
  echo "$project_real"
  run_sudo rm -rf "$project_real"
}

install_panel() {
  local server_host

  install_base_packages
  ensure_deploy_key
  ensure_docker
  clone_or_update_private_repo
  server_host="$(choose_panel_host "$(detect_server_ip)")"
  issue_panel_certificate "$server_host"
  write_server_env "$server_host"
  open_firewall_ports
  start_stack
  if [ "$PANEL_CERT_ENABLED" -eq 1 ]; then
    install_ssl_packages
    configure_nginx_https "$server_host"
  fi
  cleanup_project_dir_after_install

  echo
  echo "Panel is starting:"
  echo "http://$server_host:$PANEL_PORT"
  if [ "$PANEL_CERT_ENABLED" -eq 1 ]; then
    echo
    echo "SSL certificate was issued for: $server_host"
    echo "Use these files in your HTTPS reverse proxy:"
    echo "Key: $ACME_KEY_FILE"
    echo "Fullchain: $ACME_FULLCHAIN_FILE"
  fi
  echo
  echo "WireGuard UDP port: $WG_PORT"
  if [ -d "$PROJECT_DIR" ]; then
    echo "Private project directory: $PROJECT_DIR"
  else
    echo "Private project directory removed after install: $PROJECT_DIR"
  fi
}

receive_certificate() {
  local panel_domain

  install_ssl_packages
  panel_domain="$(choose_certificate_domain)"

  stop_nginx_for_acme
  trap 'start_nginx_after_acme' EXIT
  PANEL_CERT=yes issue_panel_certificate "$panel_domain"
  start_nginx_after_acme
  trap - EXIT

  if need_command ufw; then
    $SUDO ufw allow 80/tcp || true
    $SUDO ufw allow 443/tcp || true
  fi

  configure_nginx_https "$panel_domain"

  echo
  echo "HTTPS is ready:"
  echo "https://$panel_domain"
  echo
  echo "Certificate files:"
  echo "Key: $ACME_KEY_FILE"
  echo "Fullchain: $ACME_FULLCHAIN_FILE"
}

show_panel_info() {
  echo
  echo "Panel information"
  echo "Project directory: $PROJECT_DIR"
  if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1090
    . "$PROJECT_DIR/.env"
    echo "Domain/IP: ${WG_HOST:-unknown}"
    echo "Panel port: ${PANEL_PORT:-51821}"
    echo "WireGuard UDP port: ${WG_PUBLISHED_PORT:-${WG_PORT:-51820}}"
  else
    echo "No .env file found at $PROJECT_DIR/.env"
  fi

  if need_command docker; then
    echo
    echo "Containers:"
    $SUDO docker ps -a --filter "name=wg-easy-m3" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
  fi
}

remove_panel() {
  local confirmed

  echo
  printf '%s%s%s\n' "$RED" "DANGER: This will remove panel containers, volumes, image, and project directory." "$RESET"
  printf '%s%s%s\n' "$RED" "Type DELETE to remove the panel." "$RESET"
  printf '> '
  read -r confirmed
  confirmed="$(printf '%s' "$confirmed" | tr -cd 'A-Za-z' | tr '[:lower:]' '[:upper:]')"
  if [ "$confirmed" != "DELETE" ]; then
    echo "Remove cancelled."
    return 0
  fi

  if need_command docker; then
    if [ -d "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
      (cd "$PROJECT_DIR" && $SUDO docker compose down -v --remove-orphans) || true
    fi

    $SUDO docker rm -f wg-easy-m3 wg-easy-m3-mysql 2>/dev/null || true
    $SUDO docker volume ls --format '{{.Name}}' | grep -E '(^|_)etc_wireguard$|(^|_)mysql_data$' | xargs -r $SUDO docker volume rm 2>/dev/null || true
    $SUDO docker image rm wg-easy-m3:local 2>/dev/null || true
  fi

  if [ -d "$PROJECT_DIR" ]; then
    run_sudo rm -rf "$PROJECT_DIR"
  fi

  echo "Panel removed."
}

print_menu() {
  echo
  echo "Pasha WireGuard Panel Installer"
  echo "=============================="
  echo "1) Install panel"
  echo "2) Receive SSL certificate"
  echo "3) Panel information"
  printf '%s4) Remove panel%s\n' "$RED" "$RESET"
  echo "q) Exit"
  echo
}

run_menu_choice() {
  local choice="$1"

  case "$choice" in
    1|install)
      install_panel
      ;;
    2|cert|certificate)
      receive_certificate
      ;;
    3|info)
      show_panel_info
      ;;
    4|remove|delete|uninstall)
      remove_panel
      ;;
    q|Q|quit|exit)
      exit 0
      ;;
    *)
      echo "Invalid option: $choice" >&2
      return 1
      ;;
  esac
}

main() {
  local choice="${1:-}"

  if [ -n "$choice" ]; then
    run_menu_choice "$choice"
    return
  fi

  while true; do
    print_menu
    read -r -p "Select an option [1-4, q]: " choice
    run_menu_choice "$choice" || true
    echo
    read -r -p "Press Enter to return to the main menu..." _
  done
}

main "$@"
