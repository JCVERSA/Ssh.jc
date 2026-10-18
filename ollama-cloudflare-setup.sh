#!/usr/bin/env bash
# Ollama + Cloudflare Tunnel quick/named setup for Debian/Ubuntu containers.
# Requires root for setup/restart/stop. Quick Tunnel URLs are temporary and
# publicly reachable. This script intentionally does NOT configure Cloudflare
# Access: anyone who can reach the tunnel URL/hostname can use the Ollama API.
set -Eeuo pipefail

SUP_DIR="/etc/supervisor/conf.d"
SUP_CONF="/etc/supervisor/supervisord.conf"
LOG_DIR="/var/log/supervisor"
CF_CONF_DIR="/etc/cloudflared"
URL_FILE="/etc/ollama-cloudflare-url"
MODEL_FILE="/etc/ollama-cloudflare-model"
MODEL_DEFAULT="llama3.2:1b"
OLLAMA_USER="ollama"
CLOUDFLARED_USER="cloudflared"
OLLAMA_HOME=""

info(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }

usage(){
  echo "Usage: bash $0 [setup|status|logs|restart|stop]"
  echo "No argument opens an interactive menu."
  echo "setup, restart and stop require root; status and logs are read-only."
}

require_root(){
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
}

check_system(){
  [[ -f /etc/os-release ]] || die "Cannot identify Linux distribution."
  # /etc/os-release is a trusted runtime file provided by the OS.
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == debian || "${ID:-}" == ubuntu || "${ID_LIKE:-}" == *debian* ]] || warn "This script is designed for Debian/Ubuntu; continuing anyway."
  command -v apt-get >/dev/null || die "apt-get is required."
}

# Reads one line and prints it (or the default when the user just presses
# Enter). Returns non-zero on EOF so callers can abort instead of silently
# treating "no input" as a default choice.
prompt_value(){
  local prompt=$1 default=${2-} value
  if ! read -r -p "$prompt" value; then
    return 1
  fi
  printf '%s' "${value:-$default}"
}

is_valid_hostname(){
  local h=$1
  [[ ${#h} -le 253 ]] || return 1
  [[ "$h" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || return 1
  return 0
}

apt_update(){
  apt-get update
}

apt_install(){
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

supervisor_ctl(){
  supervisorctl -c "$SUP_CONF" "$@"
}

supervisor_program_running(){
  local program=$1
  command -v supervisorctl >/dev/null 2>&1 || return 1
  [[ -f "$SUP_CONF" ]] || return 1
  supervisor_ctl status "$program" 2>/dev/null | awk '$2 == "RUNNING" { found=1 } END { exit !found }'
}

supervisor_is_running(){
  command -v supervisorctl >/dev/null 2>&1 || return 1
  [[ -f "$SUP_CONF" ]] || return 1
  supervisor_ctl status >/dev/null 2>&1
}

tighten_log_permissions(){
  [[ -d "$LOG_DIR" ]] || return 0
  find "$LOG_DIR" -type f -name '*.log' -exec chmod 600 {} + 2>/dev/null || true
}

ensure_supervisor_running(){
  install -d -m 0750 "$SUP_DIR" "$LOG_DIR"
  if ! command -v supervisord >/dev/null || ! command -v supervisorctl >/dev/null; then
    apt_update
    apt_install supervisor
  fi
  [[ -f "$SUP_CONF" ]] || die "Supervisor config not found: $SUP_CONF"
  if ! supervisor_is_running; then
    supervisord -c "$SUP_CONF" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 10); do
      supervisor_is_running && break
      sleep 1
    done
  fi
  supervisor_is_running || die "Supervisor is not responding. Check $SUP_CONF and any existing supervisor process."
  tighten_log_permissions
}

require_supervisor_running(){
  command -v supervisorctl >/dev/null 2>&1 || die "Supervisor is not installed. Run setup first: sudo bash $0 setup"
  [[ -f "$SUP_CONF" ]] || die "Supervisor config not found: $SUP_CONF. Run setup first."
  if ! supervisor_is_running; then
    command -v supervisord >/dev/null 2>&1 || die "supervisord is not installed. Run setup first."
    supervisord -c "$SUP_CONF" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 10); do
      supervisor_is_running && break
      sleep 1
    done
  fi
  supervisor_is_running || die "Supervisor is not responding. Check $SUP_CONF and any existing supervisor process."
}

supervisor_apply(){
  supervisor_ctl reread || die "Supervisor failed to reread program configs."
  supervisor_ctl update || die "Supervisor failed to apply program configs."
  sleep 2
  tighten_log_permissions
}

ensure_service_users(){
  if ! id -u "$OLLAMA_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/ollama --shell /usr/sbin/nologin "$OLLAMA_USER" \
      || die "Could not create the dedicated '$OLLAMA_USER' system user."
  fi
  if ! id -u "$CLOUDFLARED_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$CLOUDFLARED_USER" \
      || die "Could not create the dedicated '$CLOUDFLARED_USER' system user."
  fi
  OLLAMA_HOME=$(getent passwd "$OLLAMA_USER" | cut -d: -f6)
  [[ -n "$OLLAMA_HOME" ]] || OLLAMA_HOME="/var/lib/ollama"
  install -d -o "$OLLAMA_USER" -g "$OLLAMA_USER" -m 0750 "$OLLAMA_HOME"
}

ollama_bin_path(){
  if command -v ollama >/dev/null 2>&1; then
    command -v ollama
  elif [[ -x /usr/local/bin/ollama ]]; then
    printf '%s\n' "/usr/local/bin/ollama"
  else
    return 1
  fi
}

install_ollama_binary(){
  local dpkg_arch asset tmp_dir archive sums expected actual
  dpkg_arch=$(dpkg --print-architecture 2>/dev/null || true)
  case "$dpkg_arch" in
    amd64|arm64) asset="ollama-linux-${dpkg_arch}.tar.zst" ;;
    *) die "Unsupported dpkg architecture for the verified Ollama tarball install: ${dpkg_arch:-unknown} (supported: amd64, arm64)." ;;
  esac

  apt_update
  apt_install curl ca-certificates zstd tar

  tmp_dir=$(mktemp -d "/tmp/ollama-install-XXXXXX") || die "Could not create a temporary directory."
  archive="$tmp_dir/$asset"
  sums="$tmp_dir/sha256sum.txt"
  info "Downloading Ollama release asset: $asset"
  if ! curl -fL --retry 3 "https://github.com/ollama/ollama/releases/latest/download/${asset}" -o "$archive"; then
    rm -rf "$tmp_dir"
    die "Could not download Ollama. Check outbound network access to GitHub."
  fi
  if ! curl -fsSL "https://github.com/ollama/ollama/releases/latest/download/sha256sum.txt" -o "$sums"; then
    rm -rf "$tmp_dir"
    die "Could not download the Ollama checksum file. Refusing to install an unverified archive."
  fi
  expected=$(awk -v a="$asset" '{ f=$2; sub(/^\*\/?/, "", f); sub(/^\.\//, "", f); if (f == a) print $1 }' "$sums" | head -1)
  if [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]]; then
    rm -rf "$tmp_dir"
    die "No published SHA-256 found for $asset. Refusing to install an unverified archive."
  fi
  actual=$(sha256sum "$archive" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$tmp_dir"
    die "Ollama checksum mismatch (expected $expected, got $actual). Aborting."
  fi
  ok "Ollama archive checksum verified (sha256)."

  if ! tar --zstd -xf "$archive" -C /usr/local; then
    rm -rf "$tmp_dir"
    die "Could not extract the Ollama archive into /usr/local."
  fi
  rm -rf "$tmp_dir"
  hash -r 2>/dev/null || true
  ollama_bin_path >/dev/null || die "Ollama installation failed: binary not found after extraction."
}

ollama_api_ready(){
  curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1
}

stop_unmanaged_ollama(){
  local ollama_bin=$1 expected_exe pid exe cmdline unknown=0 i
  supervisor_program_running ollama && return 0
  expected_exe=$(readlink -f "$ollama_bin" 2>/dev/null || printf '%s' "$ollama_bin")

  local pids=()
  mapfile -t pids < <(pgrep -x ollama 2>/dev/null || true)
  if [[ ${#pids[@]} -eq 0 ]]; then
    if ollama_api_ready; then
      die "Something is answering on 127.0.0.1:11434 but no Ollama process was found. Free the port or stop that service, then re-run setup."
    fi
    return 0
  fi

  for pid in "${pids[@]}"; do
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    if [[ "$exe" == "$expected_exe" && "$cmdline" == *"$ollama_bin serve"* ]]; then
      warn "Stopping the unmanaged Ollama process $pid so Supervisor can manage it."
      kill -TERM "$pid" 2>/dev/null || true
    else
      warn "Not killing Ollama-like process $pid automatically (binary/cmdline not verified: ${exe:-unknown})."
      unknown=1
    fi
  done

  for i in $(seq 1 15); do
    if ! ollama_api_ready && ! pgrep -x ollama >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  if ollama_api_ready || pgrep -x ollama >/dev/null 2>&1; then
    if [[ "$unknown" -eq 1 ]]; then
      die "An unverified process is still using Ollama/port 11434. Stop it manually, then re-run setup."
    fi
    die "The previous Ollama process did not stop in time. Stop it manually, then re-run setup."
  fi
}

install_ollama(){
  local ollama_bin
  if ollama_bin=$(ollama_bin_path); then
    ok "Ollama already installed: $("$ollama_bin" --version 2>&1 | head -1)"
  else
    info "Installing Ollama from the checksum-verified GitHub release archive..."
    install_ollama_binary
    ollama_bin=$(ollama_bin_path) || die "Ollama binary not found after installation."
    ok "Ollama installed: $("$ollama_bin" --version 2>&1 | head -1)"
  fi

  ensure_service_users

  cat > "$SUP_DIR/ollama.conf" <<EOF
[program:ollama]
command=$ollama_bin serve
user=$OLLAMA_USER
environment=OLLAMA_HOST="127.0.0.1:11434",OLLAMA_CONTEXT_LENGTH="1024",OLLAMA_KEEP_ALIVE="5m",HOME="$OLLAMA_HOME"
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
  chmod 600 "$SUP_DIR/ollama.conf"

  stop_unmanaged_ollama "$ollama_bin"
  supervisor_apply
  supervisor_ctl start ollama 2>/dev/null || true

  local i
  for i in $(seq 1 30); do
    if supervisor_program_running ollama && ollama_api_ready; then
      break
    fi
    if [[ "$i" -eq 30 ]]; then
      die "Ollama API did not start under Supervisor. Check $LOG_DIR/ollama-error.log"
    fi
    sleep 1
  done
  ok "Ollama is running under Supervisor ($OLLAMA_USER) and answers on 127.0.0.1:11434."

  local model
  if ! model=$(prompt_value "Ollama model [$MODEL_DEFAULT]: " "$MODEL_DEFAULT"); then
    die "No input received for the Ollama model; aborting instead of silently using the default."
  fi
  [[ -n "$model" ]] || die "Invalid empty Ollama model."
  info "Pulling model $model (this may take a while)..."
  if ! "$ollama_bin" pull "$model"; then
    die "Failed to pull Ollama model: $model"
  fi
  printf '%s\n' "$model" > "$MODEL_FILE"
  chmod 600 "$MODEL_FILE"
  ok "Model ready: $model"
}

install_cloudflared(){
  if command -v cloudflared >/dev/null; then
    ok "cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
    return
  fi
  apt_update
  apt_install curl ca-certificates jq
  local arch asset tmp_deb tmp_json expected actual dpkg_status
  case "$(dpkg --print-architecture)" in
    amd64) arch=amd64 ;;
    arm64) arch=arm64 ;;
    armhf) arch=arm ;;
    *) die "Unsupported dpkg architecture: $(dpkg --print-architecture)" ;;
  esac
  asset="cloudflared-linux-${arch}.deb"
  tmp_deb="$(mktemp /tmp/cloudflared-XXXXXX.deb)"
  tmp_json="$(mktemp /tmp/cloudflared-release-XXXXXX.json)"
  info "Downloading Cloudflare cloudflared package for $arch..."

  if ! curl -fsSL "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" -o "$tmp_json"; then
    rm -f "$tmp_deb" "$tmp_json"
    die "Could not read the cloudflared release metadata from GitHub. Refusing to install without a checksum."
  fi
  expected=$(jq -r --arg name "$asset" '.assets[]? | select(.name == $name) | (.digest // empty)' "$tmp_json" 2>/dev/null | sed -n 's/^sha256://p' | head -1)
  rm -f "$tmp_json"
  if [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]]; then
    rm -f "$tmp_deb"
    die "No published SHA-256 available via the GitHub API for $asset. Refusing to install an unverified package as root."
  fi
  if ! curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}" -o "$tmp_deb"; then
    rm -f "$tmp_deb"
    die "Could not download cloudflared. Check outbound network access to GitHub."
  fi
  actual=$(sha256sum "$tmp_deb" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$tmp_deb"
    die "cloudflared checksum mismatch (expected $expected, got $actual). Aborting."
  fi
  ok "cloudflared package checksum verified (sha256)."

  dpkg_status=0
  dpkg -i "$tmp_deb" || dpkg_status=1
  if [[ "$dpkg_status" -ne 0 ]]; then
    apt-get install -f -y || dpkg_status=1
    dpkg -i "$tmp_deb" || dpkg_status=1
  fi
  rm -f "$tmp_deb"
  [[ "$dpkg_status" -eq 0 ]] || die "cloudflared package installation failed."
  command -v cloudflared >/dev/null || die "cloudflared installation failed."
  ok "$(cloudflared --version 2>&1 | head -1)"
}

file_size(){
  local f=$1
  [[ -f "$f" ]] || { printf '0'; return; }
  stat -c %s "$f" 2>/dev/null || printf '0'
}

new_log_content(){
  local f=$1 offset=$2 size
  [[ -f "$f" ]] || return 0
  size=$(file_size "$f")
  if [[ "$size" -lt "$offset" ]]; then
    offset=0
  fi
  tail -c "+$((offset + 1))" "$f" 2>/dev/null || true
}

wait_for_supervisor_program(){
  local program=$1 seconds=$2 i
  for i in $(seq 1 "$seconds"); do
    if supervisor_program_running "$program"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

configure_quick_tunnel(){
  info "Configuring a temporary Cloudflare Quick Tunnel..."
  install -d -m 0750 "$LOG_DIR"
  install -d -o root -g "$CLOUDFLARED_USER" -m 0750 "$CF_CONF_DIR"
  rm -f "$URL_FILE"
  local cloudflared_bin out_log err_log out_offset err_offset url i
  cloudflared_bin=$(command -v cloudflared) || die "cloudflared binary not found."
  out_log="$LOG_DIR/cloudflared-ollama.log"
  err_log="$LOG_DIR/cloudflared-ollama-error.log"
  touch "$out_log" "$err_log"
  chmod 600 "$out_log" "$err_log"
  out_offset=$(file_size "$out_log")
  err_offset=$(file_size "$err_log")

  cat > "$SUP_DIR/cloudflared-ollama.conf" <<EOF
[program:cloudflared-ollama]
command=$cloudflared_bin tunnel --no-autoupdate --url http://127.0.0.1:11434
user=$CLOUDFLARED_USER
environment=HOME="$CF_CONF_DIR"
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
  chmod 600 "$SUP_DIR/cloudflared-ollama.conf"
  supervisor_apply
  if ! supervisor_ctl restart cloudflared-ollama 2>/dev/null; then
    supervisor_ctl start cloudflared-ollama || die "Could not start the cloudflared Quick Tunnel. Check $err_log"
  fi

  url=""
  for i in $(seq 1 60); do
    if supervisor_program_running cloudflared-ollama; then
      url=$( { new_log_content "$out_log" "$out_offset"; new_log_content "$err_log" "$err_offset"; } \
        | grep -hEo 'https://[[:alnum:]-]+\.trycloudflare\.com' | tail -1 || true )
      if [[ -n "$url" ]] && curl -fsS "${url}/api/version" >/dev/null 2>&1; then
        break
      fi
    fi
    if [[ "$i" -eq 60 ]]; then
      if [[ -n "$url" ]]; then
        die "Quick Tunnel URL was found ($url) but ${url}/api/version did not answer in time. Check $err_log"
      fi
      die "Quick Tunnel did not produce a verified URL in time. Check $err_log"
    fi
    sleep 1
  done

  printf '%s\n' "$url" > "$URL_FILE"
  chmod 600 "$URL_FILE"
  tighten_log_permissions
  echo
  ok "Quick Tunnel URL: $url"
  echo "API version: ${url}/api/version"
  echo "API chat endpoint: POST ${url}/api/chat"
  warn "Quick Tunnel URLs are temporary and may change after restart. This exposes Ollama without authentication; anyone with the URL can send requests."
}

refresh_named_tunnel_uuid(){
  local tunnel_name=$1 json count
  if ! json=$(cloudflared tunnel list --output json 2>/dev/null); then
    die "Could not list Cloudflare tunnels. Check 'cloudflared tunnel list' and your login."
  fi
  count=$(printf '%s' "$json" | jq -r --arg n "$tunnel_name" '[.[] | select(.name == $n)] | length' 2>/dev/null || printf 'invalid')
  [[ "$count" != "invalid" ]] || die "Could not parse 'cloudflared tunnel list --output json'."
  if [[ "$count" -gt 1 ]]; then
    die "Multiple Cloudflare tunnels are named '$tunnel_name'. Rename/delete the duplicates, then re-run."
  fi
  NAMED_TUNNEL_UUID=$(printf '%s' "$json" | jq -r --arg n "$tunnel_name" '.[] | select(.name == $n) | .id' | head -1)
}

configure_named_tunnel(){
  local tunnel_name hostname uuid source_cred cred_file
  echo ""
  warn "This mode uses your Cloudflare account and a domain/subdomain. It does not configure Cloudflare Access."
  if ! tunnel_name=$(prompt_value "Tunnel name [ollama-vps]: " "ollama-vps"); then
    die "No input received for the tunnel name; aborting."
  fi
  [[ "$tunnel_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "$tunnel_name" != *".."* ]] || die "Invalid tunnel name."
  if ! hostname=$(prompt_value "Public hostname (e.g. ollama.example.com): " ""); then
    die "No input received for the public hostname; aborting."
  fi
  hostname="${hostname,,}"
  is_valid_hostname "$hostname" || die "Invalid hostname."

  ensure_service_users
  rm -f "$URL_FILE"
  install -d -m 700 /root/.cloudflared
  install -d -o root -g "$CLOUDFLARED_USER" -m 0750 "$CF_CONF_DIR"

  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    info "Cloudflare will print a login URL. Open it in your browser, sign in, and authorize the domain."
    cloudflared tunnel login
  fi
  [[ -f /root/.cloudflared/cert.pem ]] || die "Cloudflare login certificate not found at /root/.cloudflared/cert.pem"
  chmod 600 /root/.cloudflared/cert.pem

  refresh_named_tunnel_uuid "$tunnel_name"
  uuid="$NAMED_TUNNEL_UUID"
  if [[ -z "$uuid" ]]; then
    cloudflared tunnel create "$tunnel_name" || die "Could not create Cloudflare tunnel '$tunnel_name'."
    refresh_named_tunnel_uuid "$tunnel_name"
    uuid="$NAMED_TUNNEL_UUID"
  else
    ok "Tunnel '$tunnel_name' already exists."
  fi
  [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Could not determine tunnel ID. Check 'cloudflared tunnel list'."
  uuid="${uuid,,}"

  source_cred="/root/.cloudflared/${uuid}.json"
  [[ -f "$source_cred" ]] || die "Tunnel credentials missing: $source_cred"
  chmod 600 "$source_cred"
  cred_file="$CF_CONF_DIR/${uuid}.json"
  install -o "$CLOUDFLARED_USER" -g "$CLOUDFLARED_USER" -m 0600 "$source_cred" "$cred_file" \
    || die "Could not copy the tunnel credentials into $CF_CONF_DIR for the dedicated cloudflared user."

  cat > "$CF_CONF_DIR/config.yml" <<EOF
tunnel: $uuid
credentials-file: $cred_file
no-autoupdate: true
ingress:
  - hostname: $hostname
    service: http://127.0.0.1:11434
  - service: http_status:404
EOF
  chown root:"$CLOUDFLARED_USER" "$CF_CONF_DIR/config.yml"
  chmod 640 "$CF_CONF_DIR/config.yml"
  cloudflared tunnel --config "$CF_CONF_DIR/config.yml" ingress validate \
    || die "Cloudflare ingress config is invalid: $CF_CONF_DIR/config.yml"

  local cloudflared_bin
  cloudflared_bin=$(command -v cloudflared) || die "cloudflared binary not found."
  cat > "$SUP_DIR/cloudflared-ollama.conf" <<EOF
[program:cloudflared-ollama]
command=$cloudflared_bin tunnel --config $CF_CONF_DIR/config.yml run $uuid
user=$CLOUDFLARED_USER
environment=HOME="$CF_CONF_DIR"
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
  chmod 600 "$SUP_DIR/cloudflared-ollama.conf"
  supervisor_apply
  if ! supervisor_ctl restart cloudflared-ollama 2>/dev/null; then
    supervisor_ctl start cloudflared-ollama || die "Could not start the named cloudflared tunnel. Check $LOG_DIR/cloudflared-ollama-error.log"
  fi

  wait_for_supervisor_program cloudflared-ollama 30 \
    || die "The named cloudflared tunnel is not RUNNING under Supervisor. Check $LOG_DIR/cloudflared-ollama-error.log"
  ollama_api_ready || die "Ollama is not answering locally, so the named tunnel cannot be verified."

  cloudflared tunnel route dns "$uuid" "$hostname" \
    || die "Could not create/update the Cloudflare DNS route for $hostname."

  local i public_url="https://${hostname}"
  for i in $(seq 1 60); do
    if curl -fsS "${public_url}/api/version" >/dev/null 2>&1; then
      break
    fi
    if [[ "$i" -eq 60 ]]; then
      die "Named tunnel is running, but ${public_url}/api/version did not answer in time. Check DNS, Cloudflare and $LOG_DIR/cloudflared-ollama-error.log"
    fi
    sleep 1
  done

  printf '%s\n' "$public_url" > "$URL_FILE"
  chmod 600 "$URL_FILE"
  tighten_log_permissions
  ok "Named tunnel configured and verified: $public_url"
  warn "No Access policy was added. The Ollama API is public at this hostname without authentication."
}

show_status(){
  echo "--- Supervisor ---"
  if command -v supervisorctl >/dev/null 2>&1 && [[ -f "$SUP_CONF" ]]; then
    supervisor_ctl status || true
  else
    echo "Supervisor is not installed/configured yet."
  fi
  echo "--- Ollama API ---"
  if command -v curl >/dev/null 2>&1 && curl -fsS http://127.0.0.1:11434/api/version; then
    echo
  else
    echo "Not responding on 127.0.0.1:11434."
  fi
  echo "--- Model ---"
  if command -v ollama >/dev/null 2>&1; then
    ollama list 2>/dev/null || true
  else
    echo "ollama binary not found."
  fi
  echo "--- Public URL ---"
  if [[ -r "$URL_FILE" ]]; then
    cat "$URL_FILE"
  elif [[ -f "$URL_FILE" ]]; then
    echo "A URL is saved but is not readable by this user (run status as root)."
  else
    echo "No URL saved yet."
  fi
}

show_logs(){
  local f shown=0
  for f in "$LOG_DIR/cloudflared-ollama.log" "$LOG_DIR/cloudflared-ollama-error.log" "$LOG_DIR/ollama.log" "$LOG_DIR/ollama-error.log"; do
    if [[ -r "$f" ]]; then
      echo "===== $f ====="
      tail -n 40 "$f"
      shown=1
    elif [[ -f "$f" ]]; then
      echo "===== $f ====="
      echo "Not readable by this user (run logs as root)."
      shown=1
    fi
  done
  [[ "$shown" -eq 1 ]] || echo "No supervisor logs found yet in $LOG_DIR."
}

stop_tunnel(){
  supervisor_ctl stop cloudflared-ollama || die "Could not stop cloudflared-ollama. Check Supervisor status and logs."
  rm -f "$URL_FILE"
  ok "Tunnel stopped. Ollama itself is still managed by Supervisor."
}

restart_services(){
  supervisor_ctl restart ollama cloudflared-ollama || die "Could not restart Ollama/cloudflared. Check Supervisor status and logs."
  wait_for_supervisor_program ollama 30 || die "Ollama is not RUNNING after restart."
  if command -v cloudflared >/dev/null 2>&1; then
    wait_for_supervisor_program cloudflared-ollama 30 || die "cloudflared-ollama is not RUNNING after restart."
  fi
  supervisor_ctl status || true
}

setup_all(){
  apt_update
  apt_install curl ca-certificates gnupg jq
  ensure_service_users
  ensure_supervisor_running
  install_ollama
  install_cloudflared
  ensure_service_users
  echo
  echo "Choose tunnel mode:"
  echo "  1) Quick Tunnel (random trycloudflare.com URL; easiest, temporary URL)"
  echo "  2) Named Tunnel (your domain + Cloudflare account; persistent hostname)"
  local mode
  if ! mode=$(prompt_value "Choice [1]: " "1"); then
    die "No input received for the tunnel mode; aborting instead of silently choosing a public Quick Tunnel."
  fi
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
    usage
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs
    ;;
  setup)
    require_root
    check_system
    setup_all
    ;;
  restart)
    require_root
    require_supervisor_running
    restart_services
    ;;
  stop)
    require_root
    require_supervisor_running
    stop_tunnel
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
    if ! choice=$(prompt_value "Choice [6]: " "6"); then
      warn "No input received; exiting."
      exit 0
    fi
    case "$choice" in
      1) require_root; check_system; setup_all ;;
      2) show_status ;;
      3) show_logs ;;
      4) require_root; require_supervisor_running; restart_services ;;
      5) require_root; require_supervisor_running; stop_tunnel ;;
      6) exit 0 ;;
      *) die "Invalid choice." ;;
    esac
    ;;
  *)
    err "Unknown argument: $1 (use --help)."
    usage >&2
    exit 1
    ;;
esac
