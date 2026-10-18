#!/usr/bin/env bash
# Ollama + Cloudflare Tunnel quick/named setup for Debian/Ubuntu containers.
# Requires root. Quick Tunnel URLs are temporary and publicly reachable.
set -Eeuo pipefail

APP_NAME="ollama-cloudflare"
SUP_DIR="/etc/supervisor/conf.d"
LOG_DIR="/var/log/supervisor"
CF_CONF_DIR="/etc/cloudflared"
MODEL_DEFAULT="llama3.2:1b"

info(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: bash $0"
[[ -f /etc/os-release ]] || die "Cannot identify Linux distribution."
. /etc/os-release
[[ "${ID:-}" == debian || "${ID:-}" == ubuntu || "${ID_LIKE:-}" == *debian* ]] || warn "This script is designed for Debian/Ubuntu; continuing anyway."
command -v apt-get >/dev/null || die "apt-get is required."

ensure_supervisor_running(){
  mkdir -p "$SUP_DIR" "$LOG_DIR"
  if ! command -v supervisord >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y supervisor
  fi
  if ! supervisorctl -c /etc/supervisor/supervisord.conf status >/dev/null 2>&1; then
    supervisord -c /etc/supervisor/supervisord.conf >/dev/null 2>&1 || true
    sleep 1
  fi
  supervisorctl -c /etc/supervisor/supervisord.conf status >/dev/null 2>&1 || die "Supervisor is not responding. Check /etc/supervisor/supervisord.conf and existing supervisor process."
}

supervisor_apply(){
  supervisorctl -c /etc/supervisor/supervisord.conf reread
  supervisorctl -c /etc/supervisor/supervisord.conf update
  sleep 2
}

install_ollama(){
  if ! command -v ollama >/dev/null; then
    info "Installing Ollama..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
    curl -fsSL https://ollama.com/install.sh | sh
  else
    ok "Ollama already installed: $(ollama --version 2>&1 | head -1)"
  fi

  cat > "$SUP_DIR/ollama.conf" <<'EOF'
[program:ollama]
command=/usr/local/bin/ollama serve
environment=OLLAMA_HOST="127.0.0.1:11434",OLLAMA_CONTEXT_LENGTH="1024",OLLAMA_KEEP_ALIVE="5m"
autostart=true
autorestart=true
startsecs=5
startretries=10
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/supervisor/ollama.log
stderr_logfile=/var/log/supervisor/ollama-error.log
EOF
  # If an Ollama instance is running outside Supervisor, stop it before Supervisor starts its managed process.
  if ! supervisorctl -c /etc/supervisor/supervisord.conf status ollama 2>/dev/null | grep -q RUNNING; then
    if pgrep -x ollama >/dev/null 2>&1; then
      warn "Stopping an unmanaged Ollama process so Supervisor can manage it."
      pkill -TERM -x ollama || true
      for _ in $(seq 1 10); do pgrep -x ollama >/dev/null || break; sleep 1; done
    fi
  fi
  supervisor_apply
  supervisorctl -c /etc/supervisor/supervisord.conf start ollama 2>/dev/null || true
  for _ in $(seq 1 20); do
    if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then break; fi
    sleep 1
  done
  curl -fsS http://127.0.0.1:11434/api/version >/dev/null || die "Ollama API did not start. Check /var/log/supervisor/ollama-error.log"

  local model
  read -r -p "Ollama model [$MODEL_DEFAULT]: " model || true
  model="${model:-$MODEL_DEFAULT}"
  info "Pulling model $model (this may take a while)..."
  ollama pull "$model"
  printf '%s\n' "$model" > /etc/ollama-cloudflare-model
  chmod 600 /etc/ollama-cloudflare-model
  ok "Model ready: $model"
}

install_cloudflared(){
  if command -v cloudflared >/dev/null; then
    ok "cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
    return
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
  local arch asset tmp
  case "$(dpkg --print-architecture)" in
    amd64) arch=amd64 ;;
    arm64) arch=arm64 ;;
    armhf) arch=arm ;;
    *) die "Unsupported dpkg architecture: $(dpkg --print-architecture)" ;;
  esac
  asset="cloudflared-linux-${arch}.deb"
  tmp="$(mktemp /tmp/cloudflared-XXXXXX.deb)"
  info "Downloading Cloudflare cloudflared package for $arch..."
  if ! curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}" -o "$tmp"; then
    rm -f "$tmp"
    die "Could not download cloudflared. Check outbound network access to GitHub."
  fi
  dpkg -i "$tmp" || { apt-get install -f -y; dpkg -i "$tmp"; }
  rm -f "$tmp"
  command -v cloudflared >/dev/null || die "cloudflared installation failed."
  ok "$(cloudflared --version 2>&1 | head -1)"
}

configure_quick_tunnel(){
  info "Configuring a temporary Cloudflare Quick Tunnel..."
  mkdir -p "$LOG_DIR"
  cat > "$SUP_DIR/cloudflared-ollama.conf" <<EOF
[program:cloudflared-ollama]
command=$(command -v cloudflared) tunnel --no-autoupdate --url http://127.0.0.1:11434
autostart=true
autorestart=true
startsecs=3
startretries=10
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/supervisor/cloudflared-ollama.log
stderr_logfile=/var/log/supervisor/cloudflared-ollama-error.log
EOF
  supervisor_apply
  supervisorctl -c /etc/supervisor/supervisord.conf restart cloudflared-ollama 2>/dev/null || supervisorctl -c /etc/supervisor/supervisord.conf start cloudflared-ollama
  sleep 5
  local url
  url="$(grep -hEo 'https://[[:alnum:]-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared-ollama.log" "$LOG_DIR/cloudflared-ollama-error.log" 2>/dev/null | tail -1 || true)"
  echo
  if [[ -n "$url" ]]; then
    ok "Quick Tunnel URL: $url"
    printf '%s\n' "$url" > /etc/ollama-cloudflare-url
    chmod 600 /etc/ollama-cloudflare-url
    echo "API version: ${url}/api/version"
    echo "API chat endpoint: POST ${url}/api/chat"
  else
    warn "Tunnel started, but its URL was not found in logs yet. Run: $0 logs"
  fi
  warn "Quick Tunnel URLs are temporary and may change after restart. This exposes Ollama without authentication; anyone with the URL can send requests."
}

configure_named_tunnel(){
  local tunnel_name hostname cert uuid cred_file
  echo ""
  warn "This mode uses your Cloudflare account and a domain/subdomain. It does not configure Cloudflare Access."
  read -r -p "Tunnel name [ollama-vps]: " tunnel_name || true
  tunnel_name="${tunnel_name:-ollama-vps}"
  [[ "$tunnel_name" =~ ^[A-Za-z0-9._-]+$ && "$tunnel_name" != *".."* ]] || die "Invalid tunnel name."
  read -r -p "Public hostname (e.g. ollama.example.com): " hostname || true
  [[ "$hostname" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || die "Invalid hostname."
  mkdir -p /root/.cloudflared "$CF_CONF_DIR"
  chmod 700 /root/.cloudflared

  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    info "Cloudflare will print a login URL. Open it in your browser, sign in, and authorize the domain."
    cloudflared tunnel login
  fi
  [[ -f /root/.cloudflared/cert.pem ]] || die "Cloudflare login certificate not found at /root/.cloudflared/cert.pem"

  if ! cloudflared tunnel list 2>/dev/null | awk 'NR>1 {print $2}' | grep -Fxq "$tunnel_name"; then
    cloudflared tunnel create "$tunnel_name"
  else
    ok "Tunnel '$tunnel_name' already exists."
  fi
  uuid="$(cloudflared tunnel list --output json | jq -r --arg n "$tunnel_name" '.[] | select(.name==$n) | .id' | head -1)"
  [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Could not determine tunnel ID. Check 'cloudflared tunnel list'."
  cred_file="/root/.cloudflared/${uuid}.json"
  [[ -f "$cred_file" ]] || die "Tunnel credentials missing: $cred_file"
  chmod 600 "$cred_file"
  cloudflared tunnel route dns "$tunnel_name" "$hostname"

  cat > "$CF_CONF_DIR/config.yml" <<EOF
 tunnel: $uuid
 credentials-file: $cred_file
 no-autoupdate: true
 ingress:
   - hostname: $hostname
     service: http://127.0.0.1:11434
   - service: http_status:404
EOF
  # Remove accidental leading spaces on top-level YAML keys.
  sed -i 's/^ tunnel:/tunnel:/; s/^ credentials-file:/credentials-file:/; s/^ no-autoupdate:/no-autoupdate:/; s/^ ingress:/ingress:/' "$CF_CONF_DIR/config.yml"
  chmod 600 "$CF_CONF_DIR/config.yml"
  cat > "$SUP_DIR/cloudflared-ollama.conf" <<EOF
[program:cloudflared-ollama]
command=$(command -v cloudflared) tunnel --config $CF_CONF_DIR/config.yml run $uuid
autostart=true
autorestart=true
startsecs=3
startretries=10
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/supervisor/cloudflared-ollama.log
stderr_logfile=/var/log/supervisor/cloudflared-ollama-error.log
EOF
  supervisor_apply
  supervisorctl -c /etc/supervisor/supervisord.conf restart cloudflared-ollama 2>/dev/null || supervisorctl -c /etc/supervisor/supervisord.conf start cloudflared-ollama
  printf 'https://%s\n' "$hostname" > /etc/ollama-cloudflare-url
  chmod 600 /etc/ollama-cloudflare-url
  ok "Named tunnel configured: https://$hostname"
  warn "No Access policy was added, as requested. The Ollama API is public at this hostname."
}

show_status(){
  echo "--- Supervisor ---"
  supervisorctl -c /etc/supervisor/supervisord.conf status || true
  echo "--- Ollama API ---"
  curl -fsS http://127.0.0.1:11434/api/version || true; echo
  echo "--- Model ---"
  ollama list 2>/dev/null || true
  echo "--- Public URL ---"
  if [[ -f /etc/ollama-cloudflare-url ]]; then cat /etc/ollama-cloudflare-url; else echo "No URL saved yet."; fi
}
show_logs(){
  for f in "$LOG_DIR/cloudflared-ollama.log" "$LOG_DIR/cloudflared-ollama-error.log" "$LOG_DIR/ollama.log" "$LOG_DIR/ollama-error.log"; do
    if [[ -f "$f" ]]; then echo "===== $f ====="; tail -n 40 "$f"; fi
  done
}

setup_all(){
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg jq
  ensure_supervisor_running
  install_ollama
  install_cloudflared
  echo
  echo "Choose tunnel mode:"
  echo "  1) Quick Tunnel (random trycloudflare.com URL; easiest, temporary URL)"
  echo "  2) Named Tunnel (your domain + Cloudflare account; persistent hostname)"
  local mode
  read -r -p "Choice [1]: " mode || true
  mode="${mode:-1}"
  case "$mode" in
    1) configure_quick_tunnel ;;
    2) configure_named_tunnel ;;
    *) die "Invalid choice." ;;
  esac
  echo
  show_status
  echo
  ok "Setup finished. Logs: $0 logs"
  warn "Supervisor can restart processes, but 24/7 uptime still depends on the hosting platform keeping this container alive and starting Supervisor again after container restart."
}

case "${1:-}" in
  --help|-h)
    echo "Usage: bash $0 [setup|status|logs|restart|stop]"
    echo "No argument opens an interactive menu."
    ;;
  setup) setup_all ;;
  status) show_status ;;
  logs) show_logs ;;
  restart)
    supervisorctl -c /etc/supervisor/supervisord.conf restart ollama cloudflared-ollama
    ;;
  stop)
    supervisorctl -c /etc/supervisor/supervisord.conf stop cloudflared-ollama
    ;;
  "")
    echo "===================================="
    echo " Ollama + Cloudflare Tunnel Manager"
    echo "===================================="
    echo "1) Full setup (Ollama + model + tunnel)"
    echo "2) Status"
    echo "3) Show logs"
    echo "4) Restart Ollama and tunnel"
    echo "5) Stop tunnel"
    echo "6) Exit"
    read -r -p "Choice [1]: " choice || true
    case "${choice:-1}" in
      1) setup_all ;;
      2) show_status ;;
      3) show_logs ;;
      4) supervisorctl -c /etc/supervisor/supervisord.conf restart ollama cloudflared-ollama ;;
      5) supervisorctl -c /etc/supervisor/supervisord.conf stop cloudflared-ollama ;;
      6) exit 0 ;;
      *) die "Invalid choice." ;;
    esac
    ;;
  *) die "Unknown argument: $1 (use --help)." ;;
esac
