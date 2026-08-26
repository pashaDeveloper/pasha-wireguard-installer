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

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

need_command() {
  command -v "$1" >/dev/null 2>&1
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
  $SUDO apt-get upgrade -y
  $SUDO apt-get install -y ca-certificates curl git openssh-client openssl
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
}

open_firewall_ports() {
  if need_command ufw; then
    $SUDO ufw allow "$WG_PORT/udp" || true
    $SUDO ufw allow "$PANEL_PORT/tcp" || true
  fi
}

start_stack() {
  cd "$PROJECT_DIR"
  $SUDO docker compose --env-file .env up -d --build
}

env_value() {
  local key="$1"
  local env_file="$PROJECT_DIR/.env"

  if [ ! -f "$env_file" ]; then
    return 0
  fi

  grep "^${key}=" "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

show_admin_users() {
  if [ ! -d "$PROJECT_DIR" ] || [ ! -f "$PROJECT_DIR/docker-compose.yml" ]; then
    echo "Admin list: panel project was not found."
    return
  fi

  if ! need_command docker; then
    echo "Admin list: Docker is not installed."
    return
  fi

  cd "$PROJECT_DIR"

  if ! $SUDO docker compose ps mysql >/dev/null 2>&1; then
    echo "Admin list: MySQL container is not available."
    return
  fi

  if ! $SUDO docker compose exec -T mysql mysql \
    -u wg_easy \
    -pwg_easy_password \
    wg_easy \
    -e "SELECT username, role, COALESCE(password_plaintext, '') AS password, created_at FROM admin_users ORDER BY role DESC, username;" 2>/dev/null; then
    echo "Admin list: could not read admin_users table. The panel may not be initialized yet."
  fi
}

show_panel_info() {
  local server_host panel_port wg_port panel_url password_hash

  server_host="$(env_value WG_HOST)"
  panel_port="$(env_value PANEL_PORT)"
  wg_port="$(env_value WG_PUBLISHED_PORT)"
  password_hash="$(env_value PASSWORD_HASH)"

  if [ -z "$server_host" ]; then
    server_host="$(detect_server_ip)"
  fi
  panel_port="${panel_port:-$PANEL_PORT}"
  wg_port="${wg_port:-$WG_PORT}"

  if [ -n "$server_host" ]; then
    panel_url="http://$server_host:$panel_port"
  else
    panel_url="Unknown. WG_HOST was not detected and .env was not found."
  fi

  echo
  echo "Panel information"
  echo "-----------------"
  echo "Panel URL: $panel_url"
  echo "Project directory: $PROJECT_DIR"
  echo "Panel TCP port: $panel_port"
  echo "WireGuard UDP port: $wg_port"
  if [ -n "$password_hash" ]; then
    echo "Password hash: $password_hash"
    echo "Plain password: cannot be recovered from PASSWORD_HASH."
  else
    echo "Password hash: not found in $PROJECT_DIR/.env"
  fi
  echo
  show_admin_users
}

uninstall_panel() {
  local confirmed remove_data remove_project

  echo
  echo "This will stop and remove the panel containers for:"
  echo "$PROJECT_DIR"
  read -r -p "Type yes to continue: " confirmed
  if [ "$confirmed" != "yes" ]; then
    echo "Canceled."
    return
  fi

  if [ -d "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
    cd "$PROJECT_DIR"
    local compose_env_args=()
    if [ -f ".env" ]; then
      compose_env_args=(--env-file .env)
    fi

    read -r -p "Also remove Docker volumes and saved panel/WireGuard data? Type yes to remove data: " remove_data
    if [ "$remove_data" = "yes" ]; then
      $SUDO docker compose "${compose_env_args[@]}" down -v --remove-orphans
    else
      $SUDO docker compose "${compose_env_args[@]}" down --remove-orphans
    fi
  else
    echo "Project directory or docker-compose.yml was not found."
  fi

  read -r -p "Remove project directory from disk too? Type yes to remove files: " remove_project
  if [ "$remove_project" = "yes" ]; then
    case "$PROJECT_DIR" in
      ""|"/"|"$HOME"|"$HOME/")
        echo "Refusing to remove unsafe PROJECT_DIR: $PROJECT_DIR"
        ;;
      *)
        if [ -f "$PROJECT_DIR/docker-compose.yml" ] || [ -d "$PROJECT_DIR/.git" ]; then
          rm -rf -- "$PROJECT_DIR"
          echo "Project directory removed."
        else
          echo "Refusing to remove PROJECT_DIR because it does not look like this panel project."
        fi
        ;;
    esac
  fi

  echo "Panel removal finished."
}

install_panel() {
  install_base_packages
  ensure_ssh_key
  ensure_docker
  clone_or_update_repo
  write_server_env "$(detect_server_ip)"
  open_firewall_ports
  start_stack

  local server_host
  server_host="$(grep '^WG_HOST=' "$PROJECT_DIR/.env" | cut -d= -f2-)"

  echo
  echo "Panel is starting:"
  echo "http://$server_host:$PANEL_PORT"
  echo
  echo "WireGuard UDP port: $WG_PORT"
  echo "Project directory: $PROJECT_DIR"
}

show_menu() {
  echo
  echo "Pasha Forever WireGuard"
  echo "-----------------------"
  echo "1) Install panel"
  echo "2) Panel information"
  echo "3) Uninstall panel"
  echo "0) Exit"
  echo
}

pause_for_menu() {
  echo
  read -r -p "Press Enter to return to the main menu..."
}

main() {
  local choice

  while true; do
    show_menu
    read -r -s -n 1 -p "Press a number: " choice
    echo

    case "$choice" in
      1)
        install_panel
        pause_for_menu
        ;;
      2)
        show_panel_info
        pause_for_menu
        ;;
      3)
        uninstall_panel
        pause_for_menu
        ;;
      0|q|Q)
        echo "Bye."
        exit 0
        ;;
      *)
        echo "Invalid option."
        pause_for_menu
        ;;
    esac
  done
}

main "$@"
