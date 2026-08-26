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

main() {
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

main "$@"
