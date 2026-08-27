#!/usr/bin/env bash
set -Eeuo pipefail

REPO_SSH_URL="${REPO_SSH_URL:-git@github.com:pashaDeveloper/pasha-forever-wireguard-3.git}"
PROJECT_DIR="${PROJECT_DIR:-$HOME/pasha-forever-wireguard-3}"
DEPLOY_KEY_PATH="${DEPLOY_KEY_PATH:-$HOME/.ssh/pasha_forever_wireguard_deploy}"
PANEL_PORT="${PANEL_PORT:-51821}"
PANEL_PORT_END="${PANEL_PORT_END:-$((PANEL_PORT + 100))}"
WG_PORT="${WG_PORT:-51820}"
LANG_VALUE="${LANG_VALUE:-fa}"
PASSWORD_HASH="${PASSWORD_HASH:-\$2a\$12\$1TMRGxEHRqYIgDMhEj1Txe9HOv7FwRY0I5s5YU.v.wziEMwZ2kK8i}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-orebu@tmvaswgcsdlcscaacsafdvgfdbybudc.com}"
ACME_KEY_FILE="${ACME_KEY_FILE:-/etc/ssl/pasha-panel/panel.key}"
ACME_FULLCHAIN_FILE="${ACME_FULLCHAIN_FILE:-/etc/ssl/pasha-panel/fullchain.cer}"
INSTALL_INFO_DIR="${INSTALL_INFO_DIR:-/etc/pasha-panel}"
INSTALL_INFO_FILE="${INSTALL_INFO_FILE:-$INSTALL_INFO_DIR/install.env}"
REMOVE_PROJECT_AFTER_INSTALL="${REMOVE_PROJECT_AFTER_INSTALL:-yes}"
PANEL_CERT_ENABLED=0

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

load_install_info() {
  if [ -f "$INSTALL_INFO_FILE" ]; then
    # shellcheck disable=SC1090
    . "$INSTALL_INFO_FILE"
  elif [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1090
    . "$PROJECT_DIR/.env"
  fi
}

choose_panel_host() {
  local detected_host="$1"
  local panel_domain="$PANEL_DOMAIN"

  echo >&2
  if [ -z "$panel_domain" ]; then
    read -r -p "Enter panel domain for WG_HOST/SSL, or press Enter to use detected IP ($detected_host): " panel_domain
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
  run_acme_step "Issuing certificate for $panel_host" "$acme_sh" --issue -d "$panel_host" --standalone

  $SUDO mkdir -p "$(dirname "$ACME_KEY_FILE")" "$(dirname "$ACME_FULLCHAIN_FILE")"
  $SUDO chown "$(id -u):$(id -g)" "$(dirname "$ACME_KEY_FILE")" "$(dirname "$ACME_FULLCHAIN_FILE")"
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

ensure_ssh_key() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  if [ ! -f "$DEPLOY_KEY_PATH.pub" ]; then
    ssh-keygen -t ed25519 -C "pasha-forever-wireguard-deploy" -f "$DEPLOY_KEY_PATH" -N ""
  fi

  chmod 600 "$DEPLOY_KEY_PATH"
  chmod 644 "$DEPLOY_KEY_PATH.pub"

  echo
  echo "Copy this SSH public key and add it to your private GitHub repository:"
  echo "GitHub repo > Settings > Deploy keys > Add deploy key"
  echo "Do not enable write access unless you really need it."
  echo
  cat "$DEPLOY_KEY_PATH.pub"
  echo

  read -r -p "Did you add this key to the repository Deploy keys? Type yes to continue: " confirmed
  if [ "$confirmed" != "yes" ]; then
    echo "Stopped. Run this script again after adding the key to GitHub."
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

  REPO_SSH_URL="${REPO_SSH_URL/git@github.com:/git@github.com-pasha-forever-wireguard:}"
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

clone_or_update_repo() {
  if [ -d "$PROJECT_DIR/.git" ]; then
    git -C "$PROJECT_DIR" pull --ff-only
  else
    git clone "$REPO_SSH_URL" "$PROJECT_DIR"
  fi
}

write_server_env() {
  local server_host="$1"
  local session_secret

  if [ -z "$server_host" ]; then
    read -r -p "Server IP was not detected. Enter WG_HOST manually: " server_host
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

  run_sudo mkdir -p "$INSTALL_INFO_DIR"
  {
    printf 'WG_HOST=%q\n' "$server_host"
    printf 'PANEL_PORT=%q\n' "$PANEL_PORT"
    printf 'PANEL_PORT_START=%q\n' "$PANEL_PORT"
    printf 'PANEL_PORT_END=%q\n' "$PANEL_PORT_END"
    printf 'WG_PUBLISHED_PORT=%q\n' "$WG_PORT"
    printf 'WG_CONFIG_PORT=%q\n' "$WG_PORT"
    printf 'PROJECT_DIR=%q\n' "$PROJECT_DIR"
    printf 'ACME_KEY_FILE=%q\n' "$ACME_KEY_FILE"
    printf 'ACME_FULLCHAIN_FILE=%q\n' "$ACME_FULLCHAIN_FILE"
  } | run_sudo tee "$INSTALL_INFO_FILE" >/dev/null
  run_sudo chmod 600 "$INSTALL_INFO_FILE"
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
  ensure_ssh_key
  ensure_docker
  clone_or_update_repo
  server_host="$(choose_panel_host "$(detect_server_ip)")"
  issue_panel_certificate "$server_host"
  write_server_env "$server_host"
  open_firewall_ports
  start_stack
  cleanup_project_dir_after_install

  load_install_info

  echo
  echo "Panel installed and starting:"
  echo "http://$WG_HOST:$PANEL_PORT"
  if [ "$PANEL_CERT_ENABLED" -eq 1 ]; then
    echo
    echo "SSL certificate was issued for: $WG_HOST"
    echo "Use these files in your HTTPS reverse proxy:"
    echo "Key: $ACME_KEY_FILE"
    echo "Fullchain: $ACME_FULLCHAIN_FILE"
  fi
  echo
  echo "WireGuard UDP port: $WG_PORT"
  echo "Project directory: $PROJECT_DIR"
}

receive_certificate() {
  local server_host

  install_base_packages
  load_install_info
  server_host="$(choose_panel_host "${WG_HOST:-$(detect_server_ip)}")"
  issue_panel_certificate "$server_host"
  open_firewall_ports

  echo
  echo "Certificate option finished."
}

show_panel_info() {
  load_install_info

  echo
  echo "Panel Information"
  echo "================="
  echo "Address: http://${WG_HOST:-unknown}:${PANEL_PORT:-51821}"
  echo "Domain/IP: ${WG_HOST:-unknown}"
  echo "Panel port: ${PANEL_PORT:-51821}"
  echo "WireGuard UDP port: ${WG_PUBLISHED_PORT:-${WG_PORT:-51820}}"
  echo "Project directory: ${PROJECT_DIR:-unknown}"
  echo "Install info file: $INSTALL_INFO_FILE"
  echo "Certificate key: ${ACME_KEY_FILE:-not set}"
  echo "Certificate fullchain: ${ACME_FULLCHAIN_FILE:-not set}"
  echo
  echo "Containers:"
  if need_command docker; then
    $SUDO docker ps -a --filter "name=wg-easy-m3" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
  else
    echo "Docker is not installed."
  fi

  echo
  echo "Panel admins:"
  if need_command docker && $SUDO docker ps --format '{{.Names}}' | grep -qx 'wg-easy-m3-mysql'; then
    $SUDO docker exec wg-easy-m3-mysql mysql -uwg_easy -pwg_easy_password wg_easy \
      -e "SELECT role, username, COALESCE(password_plaintext, '') AS password FROM admin_users ORDER BY role DESC, created_at ASC;" 2>/dev/null || \
      echo "Could not read admin users from MySQL."
  else
    echo "MySQL container is not running."
  fi
}

remove_panel() {
  local confirmed

  echo
  echo "This will remove the panel containers, database volume, WireGuard volume, image, install info, and project directory."
  read -r -p "Type DELETE to remove the panel: " confirmed
  if [ "$confirmed" != "DELETE" ]; then
    echo "Remove cancelled."
    return 0
  fi

  load_install_info

  if need_command docker; then
    if [ -d "${PROJECT_DIR:-}/" ] && [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
      (cd "$PROJECT_DIR" && $SUDO docker compose down -v --remove-orphans) || true
    fi

    $SUDO docker rm -f wg-easy-m3 wg-easy-m3-mysql 2>/dev/null || true
    $SUDO docker volume ls --format '{{.Name}}' | grep -E '(^|_)etc_wireguard$|(^|_)mysql_data$' | xargs -r $SUDO docker volume rm 2>/dev/null || true
    $SUDO docker image rm wg-easy-m3:local 2>/dev/null || true
  fi

  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    run_sudo rm -rf "$PROJECT_DIR"
  fi

  if [ -f "$INSTALL_INFO_FILE" ]; then
    run_sudo rm -f "$INSTALL_INFO_FILE"
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
  echo "4) Remove panel"
  echo
}

main() {
  local choice="${1:-}"

  if [ -z "$choice" ]; then
    print_menu
    read -r -p "Select an option [1-4]: " choice
  fi

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
    *)
      echo "Invalid option: $choice" >&2
      print_menu
      exit 1
      ;;
  esac
}

main "$@"
