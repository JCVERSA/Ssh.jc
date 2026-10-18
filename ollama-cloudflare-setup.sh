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
CF_CLI_HOME="${HOME:-/root}/.cloudflared"
URL_FILE="/etc/ollama-cloudflare-url"
MODEL_FILE="/etc/ollama-cloudflare-model"
MODEL_DEFAULT="llama3.2:1b"
OLLAMA_USER="ollama"
CLOUDFLARED_USER="cloudflared"
OLLAMA_GROUP=""
CLOUDFLARED_GROUP=""
OLLAMA_HOME=""
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-1024}"
CF_TUNNEL_PROTOCOL="${CF_TUNNEL_PROTOCOL:-auto}"
OLA_BIN_DIR="/usr/local/bin"
OLA_COMMAND="$OLA_BIN_DIR/ola"
OLA_INSTALL_DIR="/usr/local/lib/ollama-cloudflare"
OLA_SCRIPT="$OLA_INSTALL_DIR/ollama-cloudflare-setup.sh"
WATCHDOG_INTERVAL="${OLA_WATCHDOG_INTERVAL:-60}"
WATCHDOG_FAILURES="${OLA_WATCHDOG_FAILURES:-3}"
WATCHDOG_COOLDOWN="${OLA_WATCHDOG_COOLDOWN:-180}"

info(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }

usage(){
  echo "Usage: bash $0 [setup|start|recover|status|doctor|test|use|ps|unload|logs|restart|stop|watchdog]"
  echo "No argument opens an interactive menu."
  echo "setup, start, recover, use, unload, restart and stop require root; status, doctor, test, ps, logs and watchdog are read-only."
  echo "After setup, the short system command is available: ola status | ola doctor | ola test | ola recover | ola use <model> | ola start | ola logs"
  echo "ola use first unloads any different model currently in RAM, then installs/loads the requested model."
  echo "Environment: CF_TUNNEL_PROTOCOL=auto|http2|quic (default auto), OLLAMA_TMPDIR=<large temp dir>."
}

script_source_path(){
  local src=${BASH_SOURCE[0]:-} dir next
  [[ -n "$src" ]] || return 1
  if [[ "$src" != */* ]]; then
    src=$(command -v -- "$src" 2>/dev/null || true)
    [[ -n "$src" ]] || return 1
  fi
  while [[ -L "$src" ]]; do
    dir=$(cd -P "$(dirname "$src")" 2>/dev/null && pwd) || return 1
    next=$(readlink "$src" 2>/dev/null || true)
    [[ -n "$next" ]] || return 1
    if [[ "$next" == /* ]]; then
      src="$next"
    else
      src="$dir/$next"
    fi
  done
  case "$src" in
    /dev/*|/proc/*) return 1 ;;
  esac
  [[ -f "$src" ]] || return 1
  dir=$(cd -P "$(dirname "$src")" 2>/dev/null && pwd) || return 1
  printf '%s/%s' "$dir" "$(basename "$src")"
}

install_ola_command(){
  local source tmp_script existing_target
  source=$(script_source_path) \
    || die "Could not locate this script as a regular file, so the 'ola' command was not installed. Download the script to a file (for example /tmp/ollama-cloudflare-setup.sh), then run that file."
  install -d -m 0755 "$OLA_BIN_DIR" "$OLA_INSTALL_DIR" \
    || die "Could not create $OLA_INSTALL_DIR or $OLA_BIN_DIR for the 'ola' command."

  if [[ "$source" != "$OLA_SCRIPT" ]]; then
    tmp_script=$(mktemp "$OLA_INSTALL_DIR/.ollama-cloudflare-setup.sh-XXXXXX") \
      || die "Could not create a temporary file in $OLA_INSTALL_DIR for the 'ola' command."
    if ! install -m 0755 "$source" "$tmp_script"; then
      rm -f "$tmp_script"
      die "Could not install this script as $OLA_SCRIPT."
    fi
    mv -f "$tmp_script" "$OLA_SCRIPT" \
      || die "Could not install this script as $OLA_SCRIPT."
  fi
  chmod 0755 "$OLA_SCRIPT" || die "Could not make $OLA_SCRIPT executable."

  if [[ -L "$OLA_COMMAND" ]]; then
    existing_target=$(readlink -f "$OLA_COMMAND" 2>/dev/null || true)
    [[ "$existing_target" == "$OLA_SCRIPT" ]] \
      || die "$OLA_COMMAND already exists and points to '${existing_target:-unknown}', not to this tool. Refusing to overwrite it; rename/remove that command, then re-run."
  elif [[ -e "$OLA_COMMAND" ]]; then
    cmp -s "$OLA_COMMAND" "$OLA_SCRIPT" \
      || die "$OLA_COMMAND already exists and is not this tool. Refusing to overwrite it; rename/remove that file, then re-run."
  fi
  ln -sfn "$OLA_SCRIPT" "$OLA_COMMAND" \
    || die "Could not create the short command $OLA_COMMAND."
  hash -r 2>/dev/null || true
  case ":$PATH:" in
    *":$OLA_BIN_DIR:"*) ;;
    *) warn "$OLA_BIN_DIR is not in the current PATH. Use $OLA_COMMAND in this shell, or open a new root shell before typing: ola" ;;
  esac
  ok "Short command installed: ola (examples: ola, ola status, ola start, ola logs)"
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
  apt-get -o DPkg::Lock::Timeout=120 update
}

apt_install(){
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y "$@"
}

free_kb(){
  local path=$1 kb
  kb=$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  printf '%s' "$kb"
}

require_commands(){
  local cmd missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Required command not found: $cmd"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "Missing required commands. Install the base packages first (see setup output above)."
}

nologin_shell(){
  local candidate
  for candidate in /usr/sbin/nologin /sbin/nologin /usr/bin/false /bin/false; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf '%s' "/bin/false"
}

# Verifies an HTTPS URL even when the container resolver cannot resolve the
# public hostname: falls back to Cloudflare DNS-over-HTTPS plus --resolve.
https_url_ready(){
  local url=$1 host json ips ip
  if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 1
  host=${url#*://}
  host=${host%%/*}
  [[ -n "$host" && "$host" != "$url" ]] || return 1
  json=$(curl -fsS --max-time 10 "https://1.1.1.1/dns-query?name=${host}&type=A" -H 'accept: application/dns-json' 2>/dev/null) || return 1
  ips=$(printf '%s' "$json" | jq -r '.Answer[]? | select(.type == 1) | .data' 2>/dev/null || true)
  for ip in $ips; do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if curl -fsS --max-time 10 --resolve "${host}:443:${ip}" "$url" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

ollama_pids(){
  local proc comm
  for proc in /proc/[0-9]*; do
    [[ -r "$proc/comm" ]] || continue
    comm=$(<"$proc/comm")
    if [[ "$comm" == "ollama" ]]; then
      printf '%s\n' "${proc#/proc/}"
    fi
  done
}

any_ollama_process(){
  [[ -n "$(ollama_pids)" ]]
}

select_supervisor_paths(){
  if [[ -f /etc/supervisor/supervisord.conf ]]; then
    SUP_CONF="/etc/supervisor/supervisord.conf"
    SUP_DIR="/etc/supervisor/conf.d"
  elif [[ -f /etc/supervisord.conf ]]; then
    SUP_CONF="/etc/supervisord.conf"
    if [[ -d /etc/supervisord.d ]]; then
      SUP_DIR="/etc/supervisord.d"
    elif [[ -d /etc/supervisor/conf.d ]]; then
      SUP_DIR="/etc/supervisor/conf.d"
    fi
  fi
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
  select_supervisor_paths
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
  select_supervisor_paths
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
  local shell_path
  shell_path=$(nologin_shell)
  if ! id -u "$OLLAMA_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/ollama --shell "$shell_path" "$OLLAMA_USER" \
      || die "Could not create the dedicated '$OLLAMA_USER' system user."
  fi
  if ! id -u "$CLOUDFLARED_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell "$shell_path" "$CLOUDFLARED_USER" \
      || die "Could not create the dedicated '$CLOUDFLARED_USER' system user."
  fi
  OLLAMA_GROUP=$(id -gn "$OLLAMA_USER" 2>/dev/null || printf '%s' "$OLLAMA_USER")
  CLOUDFLARED_GROUP=$(id -gn "$CLOUDFLARED_USER" 2>/dev/null || printf '%s' "$CLOUDFLARED_USER")
  OLLAMA_HOME=$(getent passwd "$OLLAMA_USER" | cut -d: -f6)
  case "$OLLAMA_HOME" in
    ""|"/"|"/nonexistent"|"/root") OLLAMA_HOME="/var/lib/ollama" ;;
  esac
  install -d -o "$OLLAMA_USER" -g "$OLLAMA_GROUP" -m 0750 "$OLLAMA_HOME"
}

ollama_version_text(){
  local bin=$1 ver
  ver=$("$bin" --version 2>/dev/null | grep -Ei 'ollama version|version is [0-9]' | head -1 || true)
  [[ -n "$ver" ]] || ver="binary at $bin"
  printf '%s' "$ver"
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


large_tmp_parent(){
  local candidates=() candidate kb best="" best_kb=0
  if [[ -n "${OLLAMA_TMPDIR:-}" ]]; then
    mkdir -p "$OLLAMA_TMPDIR" 2>/dev/null || return 1
    [[ -w "$OLLAMA_TMPDIR" ]] || return 1
    printf '%s' "$OLLAMA_TMPDIR"
    return 0
  fi
  [[ -n "${TMPDIR:-}" ]] && candidates+=("$TMPDIR")
  candidates+=(/var/tmp /tmp)
  for candidate in "${candidates[@]}"; do
    mkdir -p "$candidate" 2>/dev/null || continue
    [[ -w "$candidate" ]] || continue
    kb=$(df -Pk "$candidate" 2>/dev/null | awk 'NR == 2 { print $4 }')
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    if [[ "$kb" -gt "$best_kb" ]]; then
      best="$candidate"
      best_kb="$kb"
    fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s' "$best"
}

checksum_for_asset(){
  local sums=$1 asset=$2
  awk -v a="$asset" '{ f=$2; sub(/\r$/, "", f); sub(/^\*\/?/, "", f); sub(/^\.\//, "", f); if (f == a) { print $1; exit } }' "$sums"
}

install_ollama_binary(){
  local dpkg_arch tmp_dir archive sums expected actual candidate tmp_parent tmp_kb usr_kb tmp_dev usr_dev
  dpkg_arch=$(dpkg --print-architecture 2>/dev/null || true)
  case "$dpkg_arch" in
    amd64|arm64) ;;
    *) die "Unsupported dpkg architecture for the verified Ollama tarball install: ${dpkg_arch:-unknown} (supported: amd64, arm64)." ;;
  esac

  apt_update
  apt_install curl ca-certificates tar

  tmp_parent=$(large_tmp_parent) || die "Could not find a writable temporary directory. Set OLLAMA_TMPDIR to a directory on a disk with at least 3 GB free."
  tmp_dir=$(mktemp -d "$tmp_parent/ollama-install-XXXXXX") || die "Could not create a temporary directory in $tmp_parent."
  sums="$tmp_dir/sha256sum.txt"
  info "Downloading Ollama checksum list (temporary directory: $tmp_dir)..."
  if ! curl -fsSL --retry 3 "https://github.com/ollama/ollama/releases/latest/download/sha256sum.txt" -o "$sums"; then
    rm -rf "$tmp_dir"
    die "Could not download the Ollama checksum file. Check DNS/network access to GitHub. Refusing to install an unverified archive."
  fi

  local asset=""
  for candidate in "ollama-linux-${dpkg_arch}.tar.zst" "ollama-linux-${dpkg_arch}.tgz" "ollama-linux-${dpkg_arch}.tar.gz"; do
    expected=$(checksum_for_asset "$sums" "$candidate")
    if [[ "$expected" =~ ^[a-f0-9]{64}$ ]]; then
      asset="$candidate"
      break
    fi
  done
  if [[ -z "$asset" ]]; then
    rm -rf "$tmp_dir"
    die "No compatible published Ollama archive found for architecture '$dpkg_arch' in sha256sum.txt."
  fi
  if [[ "$asset" == *.tar.zst ]]; then
    apt_install zstd
  fi

  # Download + extraction together need roughly 3 GB when both live on the
  # same filesystem (compressed archive plus extracted binaries/libraries).
  tmp_kb=$(free_kb "$tmp_parent")
  usr_kb=$(free_kb /usr/local)
  tmp_dev=$(stat -c %d "$tmp_parent" 2>/dev/null || printf '?')
  usr_dev=$(stat -c %d /usr/local 2>/dev/null || printf '?')
  if [[ "$tmp_dev" == "$usr_dev" ]]; then
    if [[ "$tmp_kb" -gt 0 && "$tmp_kb" -lt 3000000 ]]; then
      rm -rf "$tmp_dir"
      die "Not enough free disk space on $tmp_parent for the Ollama download plus extraction (need about 3 GB free). Free space or set OLLAMA_TMPDIR to a larger disk."
    fi
  else
    if [[ "$tmp_kb" -gt 0 && "$tmp_kb" -lt 1700000 ]] || [[ "$usr_kb" -gt 0 && "$usr_kb" -lt 1700000 ]]; then
      rm -rf "$tmp_dir"
      die "Not enough free disk space for Ollama (need about 1.7 GB free in the temp dir and on /usr/local). Check 'df -h'."
    fi
  fi

  archive="$tmp_dir/$asset"
  info "Downloading Ollama release asset: $asset"
  if ! curl -fL --retry 3 "https://github.com/ollama/ollama/releases/latest/download/${asset}" -o "$archive"; then
    rm -rf "$tmp_dir"
    die "Could not download Ollama. This is usually a network/DNS error or not enough free disk space; check 'df -h' and outbound access to GitHub."
  fi
  actual=$(sha256sum "$archive" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$tmp_dir"
    die "Ollama checksum mismatch (expected $expected, got $actual). Aborting."
  fi
  ok "Ollama archive checksum verified (sha256)."

  if ! tar -xaf "$archive" -C /usr/local; then
    rm -rf "$tmp_dir"
    die "Could not extract the Ollama archive into /usr/local (disk full or unsupported archive format)."
  fi
  rm -rf "$tmp_dir"
  hash -r 2>/dev/null || true
  ollama_bin_path >/dev/null || die "Ollama installation failed: binary not found after extraction."
}

ollama_api_ready(){
  curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1
}


is_valid_model_name(){
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]
}

normalize_model_name(){
  local model=$1 last_part
  last_part=${model##*/}
  if [[ "$last_part" == *:* ]]; then
    printf '%s' "$model"
  else
    printf '%s:latest' "$model"
  fi
}

loaded_model_names(){
  curl -fsS --max-time 10 http://127.0.0.1:11434/api/ps 2>/dev/null \
    | jq -r '.models[]?.name // empty'
}

installed_model_names(){
  curl -fsS --max-time 10 http://127.0.0.1:11434/api/tags 2>/dev/null \
    | jq -r '.models[]?.name // empty'
}

model_names_contain(){
  local names=$1 target=$2 name target_norm
  target_norm=$(normalize_model_name "$target")
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$(normalize_model_name "$name")" == "$target_norm" ]] && return 0
  done <<< "$names"
  return 1
}

unload_model(){
  local model=$1 payload names i
  is_valid_model_name "$model" || return 1
  payload=$(jq -cn --arg model "$model" '{model:$model, keep_alive:0}') || return 1
  curl -fsS --max-time 30 http://127.0.0.1:11434/api/generate \
    -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1 || return 1
  for i in $(seq 1 30); do
    names=$(loaded_model_names) || return 1
    model_names_contain "$names" "$model" || return 0
    sleep 1
  done
  return 1
}

# Unloads every model currently held in RAM except, optionally, one target.
# This frees RAM; it does not delete model files from disk.
stop_loaded_models_except(){
  local target=${1:-} target_norm="__none__" loaded_names loaded
  if [[ -n "$target" ]]; then
    target_norm=$(normalize_model_name "$target")
  fi
  loaded_names=$(loaded_model_names) \
    || die "Could not read the list of models currently loaded in RAM from Ollama. Refusing to switch models blindly."
  while IFS= read -r loaded; do
    [[ -n "$loaded" ]] || continue
    if [[ "$(normalize_model_name "$loaded")" != "$target_norm" ]]; then
      info "Unloading current model from RAM first: $loaded"
      unload_model "$loaded" \
        || die "Could not unload the currently loaded model: $loaded. It may be busy; try again in a moment."
      ok "Model unloaded from RAM: $loaded"
    fi
  done <<< "$loaded_names"
}

pull_model_with_retry(){
  local model=$1 ollama_bin=$2 models_kb pull_attempt
  models_kb=$(free_kb "$OLLAMA_HOME")
  if [[ "$models_kb" -gt 0 && "$models_kb" -lt 2000000 ]]; then
    warn "Less than about 2 GB free on $OLLAMA_HOME. A larger model may fail while pulling; free disk space if needed."
  fi
  info "Pulling model $model (this may take a while)..."
  for pull_attempt in 1 2; do
    if "$ollama_bin" pull "$model"; then
      return 0
    fi
    if [[ "$pull_attempt" -eq 2 ]]; then
      die "Failed to pull Ollama model: $model (check network, disk space and the exact model name)."
    fi
    warn "Model pull failed (attempt 1/2); retrying in 5 seconds..."
    sleep 5
  done
}

show_loaded_models(){
  local names
  if ! names=$(loaded_model_names); then
    die "Ollama API is not answering, so loaded models cannot be listed. Try: ola recover"
  fi
  if [[ -z "$names" ]]; then
    echo "No model is currently loaded in RAM."
  else
    echo "Models currently loaded in RAM:"
    printf '%s\n' "$names"
  fi
}

unload_models_command(){
  local target=${1:-} loaded_names
  require_commands curl jq
  ollama_api_ready || die "Ollama API is not answering. Try: ola recover"
  if [[ -n "$target" ]]; then
    is_valid_model_name "$target" || die "Invalid model name: $target"
    loaded_names=$(loaded_model_names) || die "Could not list loaded models."
    if ! model_names_contain "$loaded_names" "$target"; then
      ok "Model is not currently loaded in RAM: $target"
      return 0
    fi
    info "Unloading model from RAM: $target"
    unload_model "$target" || die "Could not unload model: $target"
    ok "Model unloaded from RAM: $target"
  else
    stop_loaded_models_except ""
    ok "All loaded models have been unloaded from RAM. The Ollama service itself is still running."
  fi
}

switch_model(){
  local target=$1 ollama_bin installed_names loaded_names payload response content mem_kb
  is_valid_model_name "$target" || die "Invalid model name: $target (example: llama3.2:1b)"
  require_commands curl jq
  ollama_bin=$(ollama_bin_path) || die "Ollama binary not found. Run setup first: ola setup"
  ensure_service_users

  if ! supervisor_program_running ollama; then
    info "Ollama is not RUNNING; starting it before switching models..."
    supervisor_ctl start ollama 2>/dev/null || supervisor_ctl restart ollama \
      || die "Could not start Ollama. Check: ola logs"
    wait_for_supervisor_program ollama 30 || die "Ollama did not reach RUNNING. Check: ola logs"
  fi
  ollama_api_ready || die "Ollama API is not answering. Try: ola recover"

  info "Switching to model: $target"
  stop_loaded_models_except "$target"

  installed_names=$(installed_model_names) \
    || die "Could not read the installed model list from Ollama."
  if model_names_contain "$installed_names" "$target"; then
    ok "Model already downloaded: $target"
  else
    pull_model_with_retry "$target" "$ollama_bin"
  fi

  # Pulling does not load a model, but stop again in case another request
  # loaded a different model while the download was running.
  stop_loaded_models_except "$target"
  loaded_names=$(loaded_model_names) || die "Could not verify loaded models after download."
  if model_names_contain "$loaded_names" "$target"; then
    ok "Model already loaded in RAM: $target"
  else
    info "Loading model into RAM: $target"
    payload=$(jq -cn --arg model "$target" '{model:$model, messages:[{role:"user", content:"Reply only with OK."}], stream:false}') \
      || die "Could not build the model loading request."
    if ! response=$(curl -fsS --max-time 180 http://127.0.0.1:11434/api/chat \
      -H 'Content-Type: application/json' -d "$payload" 2>/dev/null); then
      die "Model $target was downloaded but could not be loaded. Check RAM and: ola logs"
    fi
    content=$(printf '%s' "$response" | jq -r '.message.content // .response // empty' 2>/dev/null || true)
    ok "Model loaded and answered: ${content:-OK}"
  fi

  stop_loaded_models_except "$target"
  loaded_names=$(loaded_model_names) || die "Could not verify the final loaded model list."
  model_names_contain "$loaded_names" "$target" \
    || die "Model $target did not remain loaded. Check: ola logs"

  printf '%s\n' "$target" > "$MODEL_FILE" || die "Could not save the default model to $MODEL_FILE."
  chmod 600 "$MODEL_FILE" || die "Could not set permissions on $MODEL_FILE."
  mem_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
  ok "Default model is now: $target (previous models were unloaded from RAM, not deleted from disk)."
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    info "Available RAM now: about $((mem_kb / 1024)) MB"
  fi
}

stop_unmanaged_ollama(){
  local ollama_bin=$1 expected_exe pid exe cmdline unknown=0 i pid_list p
  supervisor_program_running ollama && return 0
  expected_exe=$(readlink -f "$ollama_bin" 2>/dev/null || printf '%s' "$ollama_bin")

  local pids=()
  # Do not use Bash process substitution here: some minimal containers do not
  # provide /dev/fd, which made the previous mapfile line abort the setup.
  pid_list=$(ollama_pids)
  # shellcheck disable=SC2086 # ollama_pids prints a list of numeric PIDs.
  for p in $pid_list; do pids+=("$p"); done
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
    if ! ollama_api_ready && ! any_ollama_process; then
      return 0
    fi
    sleep 1
  done

  if ollama_api_ready || any_ollama_process; then
    if [[ "$unknown" -eq 1 ]]; then
      die "An unverified process is still using Ollama/port 11434. Stop it manually, then re-run setup."
    fi
    die "The previous Ollama process did not stop in time. Stop it manually, then re-run setup."
  fi
}

install_ollama(){
  local ollama_bin
  if ollama_bin=$(ollama_bin_path); then
    ok "Ollama already installed: $(ollama_version_text "$ollama_bin")"
  else
    info "Installing Ollama from the checksum-verified GitHub release archive..."
    install_ollama_binary
    ollama_bin=$(ollama_bin_path) || die "Ollama binary not found after installation."
    ok "Ollama installed: $(ollama_version_text "$ollama_bin")"
  fi

  ensure_service_users

  # The tunnel deliberately exposes Ollama without Cloudflare Access. Ollama
  # has two separate 403 guards: OLLAMA_ORIGINS controls browser Origin
  # headers, while its Host check rejects public tunnel hostnames. The
  # origin allow-list is opened here, and cloudflared rewrites the Host
  # header to localhost:11434 in both tunnel modes below.
  cat > "$SUP_DIR/ollama.conf" <<EOF
[program:ollama]
command=$ollama_bin serve
user=$OLLAMA_USER
environment=OLLAMA_HOST="127.0.0.1:11434",OLLAMA_ORIGINS="*",OLLAMA_CONTEXT_LENGTH="$OLLAMA_CONTEXT_LENGTH",OLLAMA_KEEP_ALIVE="5m",OLLAMA_MAX_LOADED_MODELS="1",OLLAMA_NUM_PARALLEL="1",HOME="$OLLAMA_HOME"
autostart=true
autorestart=true
startsecs=5
startretries=10
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/supervisor/ollama.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile=/var/log/supervisor/ollama-error.log
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3
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
  is_valid_model_name "$model" || die "Invalid Ollama model name: $model"
  stop_loaded_models_except "$model"
  pull_model_with_retry "$model" "$ollama_bin"
  printf '%s\n' "$model" > "$MODEL_FILE"
  chmod 600 "$MODEL_FILE"
  ok "Model ready: $model"
}

install_cloudflared_github_verified(){
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
  local tmp_parent
  tmp_parent=$(large_tmp_parent || printf '%s' "/tmp")
  tmp_deb="$(mktemp "$tmp_parent/cloudflared-XXXXXX.deb")"
  tmp_json="$(mktemp "$tmp_parent/cloudflared-release-XXXXXX.json")"
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
    apt_install -f || dpkg_status=1
    dpkg -i "$tmp_deb" || dpkg_status=1
  fi
  rm -f "$tmp_deb"
  [[ "$dpkg_status" -eq 0 ]] || die "cloudflared package installation failed."
  command -v cloudflared >/dev/null || die "cloudflared installation failed."
  ok "$(cloudflared --version 2>&1 | head -1)"
}


install_cloudflared_official_repo(){
  if command -v cloudflared >/dev/null; then
    return 0
  fi
  apt_install curl gnupg ca-certificates apt-transport-https || return 1
  install -d -m 0755 /usr/share/keyrings || return 1
  info "Adding the official Cloudflare apt repository..."
  if ! curl -fsSL "https://pkg.cloudflare.com/cloudflare-main.gpg" | gpg --batch --yes --dearmor -o /usr/share/keyrings/cloudflare-main.gpg; then
    return 1
  fi
  chmod 644 /usr/share/keyrings/cloudflare-main.gpg || return 1
  printf '%s\n' "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null || return 1
  apt_update || return 1
  apt_install cloudflared || return 1
  command -v cloudflared >/dev/null
}

install_cloudflared(){
  if command -v cloudflared >/dev/null; then
    ok "cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
    return
  fi
  info "Trying the official Cloudflare apt repository first..."
  if install_cloudflared_official_repo; then
    ok "cloudflared installed: $(cloudflared --version 2>&1 | head -1)"
    return
  fi
  warn "The official Cloudflare repository method failed. Falling back to the verified GitHub .deb..."
  install_cloudflared_github_verified
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
  install -d -o root -g "$CLOUDFLARED_GROUP" -m 0750 "$CF_CONF_DIR"
  rm -f "$URL_FILE"
  local cloudflared_bin out_log err_log out_offset err_offset url i protocol_flag=""
  cloudflared_bin=$(command -v cloudflared) || die "cloudflared binary not found."
  if [[ "$CF_TUNNEL_PROTOCOL" != "auto" ]]; then
    protocol_flag=" --protocol=$CF_TUNNEL_PROTOCOL"
  fi
  out_log="$LOG_DIR/cloudflared-ollama.log"
  err_log="$LOG_DIR/cloudflared-ollama-error.log"
  touch "$out_log" "$err_log"
  chmod 600 "$out_log" "$err_log"
  out_offset=$(file_size "$out_log")
  err_offset=$(file_size "$err_log")

  cat > "$SUP_DIR/cloudflared-ollama.conf" <<EOF
[program:cloudflared-ollama]
command=$cloudflared_bin tunnel --no-autoupdate$protocol_flag --url http://127.0.0.1:11434 --http-host-header=localhost:11434
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
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile=/var/log/supervisor/cloudflared-ollama-error.log
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3
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
      if [[ -n "$url" ]] && https_url_ready "${url}/api/version"; then
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
  local tunnel_name hostname uuid source_cred cred_file protocol_line="" candidate_home alt_home
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
  if [[ ! -f "$CF_CLI_HOME/cert.pem" ]]; then
    for candidate_home in "/root/.cloudflared" "${HOME:-}/.cloudflared"; do
      if [[ -n "$candidate_home" && "$candidate_home" != "$CF_CLI_HOME" && -f "$candidate_home/cert.pem" ]]; then
        install -d -m 700 "$CF_CLI_HOME"
        install -m 0600 "$candidate_home/cert.pem" "$CF_CLI_HOME/cert.pem"
        info "Using the existing Cloudflare login certificate from $candidate_home."
        break
      fi
    done
  fi
  if [[ ! -f "$CF_CLI_HOME/cert.pem" && -n "${SUDO_USER:-}" ]]; then
    alt_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
    if [[ -n "$alt_home" && -f "$alt_home/.cloudflared/cert.pem" ]]; then
      install -d -m 700 "$CF_CLI_HOME"
      install -m 0600 "$alt_home/.cloudflared/cert.pem" "$CF_CLI_HOME/cert.pem"
      info "Using the existing Cloudflare login certificate from $alt_home/.cloudflared."
    fi
  fi
  rm -f "$URL_FILE"
  install -d -m 700 "$CF_CLI_HOME"
  install -d -o root -g "$CLOUDFLARED_GROUP" -m 0750 "$CF_CONF_DIR"

  if [[ ! -f "$CF_CLI_HOME/cert.pem" ]]; then
    info "Cloudflare will print a login URL. Open it in your browser, sign in, and authorize the domain."
    cloudflared tunnel login || die "Cloudflare login failed or was cancelled. Re-run setup and complete the browser authorization."
  fi
  [[ -f "$CF_CLI_HOME/cert.pem" ]] || die "Cloudflare login certificate not found at $CF_CLI_HOME/cert.pem"
  chmod 600 "$CF_CLI_HOME/cert.pem"

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

  source_cred="$CF_CLI_HOME/${uuid}.json"
  [[ -f "$source_cred" ]] || die "Tunnel credentials missing: $source_cred"
  chmod 600 "$source_cred"
  cred_file="$CF_CONF_DIR/${uuid}.json"
  install -o "$CLOUDFLARED_USER" -g "$CLOUDFLARED_GROUP" -m 0600 "$source_cred" "$cred_file" \
    || die "Could not copy the tunnel credentials into $CF_CONF_DIR for the dedicated cloudflared user."

  if [[ "$CF_TUNNEL_PROTOCOL" != "auto" ]]; then
    protocol_line="protocol: $CF_TUNNEL_PROTOCOL"
  fi
  cat > "$CF_CONF_DIR/config.yml" <<EOF
tunnel: $uuid
credentials-file: $cred_file
no-autoupdate: true
$protocol_line
ingress:
  - hostname: $hostname
    service: http://127.0.0.1:11434
    originRequest:
      httpHostHeader: "localhost:11434"
  - service: http_status:404
EOF
  chown root:"$CLOUDFLARED_GROUP" "$CF_CONF_DIR/config.yml"
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
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile=/var/log/supervisor/cloudflared-ollama-error.log
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3
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
    || die "Could not create/update the Cloudflare DNS route for $hostname. If a DNS record already exists for this hostname, delete/repoint it in Cloudflare DNS, then re-run setup."

  local i public_url="https://${hostname}" public_verified=0
  info "Waiting up to 2 minutes for ${public_url}/api/version (DNS/Cloudflare propagation)..."
  for i in $(seq 1 60); do
    if https_url_ready "${public_url}/api/version"; then
      public_verified=1
      break
    fi
    if [[ "$i" -eq 20 || "$i" -eq 40 ]]; then
      info "Still waiting for the public hostname to answer..."
    fi
    sleep 2
  done

  printf '%s\n' "$public_url" > "$URL_FILE"
  chmod 600 "$URL_FILE"
  tighten_log_permissions
  if [[ "$public_verified" -eq 1 ]]; then
    ok "Named tunnel configured and verified: $public_url"
  else
    # The connector is RUNNING, ingress was validated and Cloudflare accepted
    # the DNS route. A probe from the same server can still fail because of
    # DNS propagation/cache or hairpin routing, so do not throw away an
    # otherwise working tunnel: save the URL and report the probe honestly.
    warn "Named tunnel is configured and its DNS route was created, but the public probe from this server did not confirm ${public_url}/api/version yet."
    warn "Test it from a browser or another device: ${public_url}/api/version"
    supervisor_ctl status || true
    cloudflared tunnel info "$uuid" 2>/dev/null || true
    if [[ -r "$LOG_DIR/cloudflared-ollama-error.log" ]]; then
      echo "--- Last cloudflared log lines ---"
      tail -n 30 "$LOG_DIR/cloudflared-ollama-error.log" || true
    fi
    ok "Named tunnel configured: $public_url (public answer not yet confirmed from this server)"
  fi
  warn "No Access policy was added. The Ollama API is public at this hostname without authentication."
}

show_status(){
  select_supervisor_paths
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
    if command -v supervisorctl >/dev/null 2>&1 && [[ -f "$SUP_CONF" ]] && ! supervisor_program_running cloudflared-ollama; then
      echo "(saved URL, but cloudflared-ollama is not RUNNING right now)"
    fi
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


saved_model_name(){
  local model=""
  if [[ -r "$MODEL_FILE" ]]; then
    model=$(head -n 1 "$MODEL_FILE" 2>/dev/null || true)
  fi
  [[ -n "$model" ]] || model="$MODEL_DEFAULT"
  printf '%s' "$model"
}

ollama_home_for_status(){
  local home_dir
  home_dir=$(getent passwd "$OLLAMA_USER" 2>/dev/null | cut -d: -f6 || true)
  case "$home_dir" in
    ""|"/"|"/nonexistent"|"/root") home_dir="/var/lib/ollama" ;;
  esac
  printf '%s' "$home_dir"
}

# 0 = cloudflared reports ready, 1 = it definitively reports not ready,
# 2 = the local metrics endpoint is unavailable/unknown. Watchdog and
# recover only act on the definitive "not ready" state, never on "unknown".
cloudflared_ready_state(){
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:20241/ready 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    return 0
  fi
  if [[ -z "$code" || "$code" == "000" ]]; then
    return 2
  fi
  return 1
}

wait_cloudflared_ready(){
  local seconds=$1 i state=2
  [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=30
  for ((i=1; i<=seconds; i++)); do
    state=0
    cloudflared_ready_state || state=$?
    [[ "$state" -eq 0 ]] && return 0
    sleep 1
  done
  return "$state"
}

ensure_watchdog(){
  select_supervisor_paths
  install -d -m 0750 "$LOG_DIR" "$SUP_DIR" \
    || die "Could not create Supervisor directories for the watchdog."
  cat > "$SUP_DIR/ollama-watchdog.conf" <<EOF
[program:ollama-watchdog]
command=$OLA_SCRIPT watchdog-daemon
environment=HOME="/root"
autostart=true
autorestart=true
startsecs=5
startretries=999999
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/supervisor/ollama-watchdog.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile=/var/log/supervisor/ollama-watchdog-error.log
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3
EOF
  chmod 600 "$SUP_DIR/ollama-watchdog.conf" \
    || die "Could not set permissions on $SUP_DIR/ollama-watchdog.conf"
  if supervisor_is_running; then
    supervisor_apply
    if supervisor_program_running ollama-watchdog; then
      supervisor_ctl restart ollama-watchdog >/dev/null 2>&1 || true
    else
      supervisor_ctl start ollama-watchdog >/dev/null 2>&1 || true
    fi
  fi
  ok "Health watchdog enabled (checks every ${WATCHDOG_INTERVAL}s; restart after ${WATCHDOG_FAILURES} failed checks)."
}

watchdog_log(){
  printf '%s [watchdog] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

watchdog_sleep(){
  local seconds=$1 pid
  sleep "$seconds" &
  pid=$!
  wait "$pid" 2>/dev/null || true
}

run_watchdog_daemon(){
  local ollama_failures=0 cloudflared_failures=0 state
  select_supervisor_paths
  case "$WATCHDOG_INTERVAL" in ""|*[!0-9]*) die "Invalid OLA_WATCHDOG_INTERVAL='$WATCHDOG_INTERVAL'." ;; esac
  case "$WATCHDOG_FAILURES" in ""|*[!0-9]*) die "Invalid OLA_WATCHDOG_FAILURES='$WATCHDOG_FAILURES'." ;; esac
  case "$WATCHDOG_COOLDOWN" in ""|*[!0-9]*) die "Invalid OLA_WATCHDOG_COOLDOWN='$WATCHDOG_COOLDOWN'." ;; esac
  [[ "$WATCHDOG_INTERVAL" -ge 10 ]] || die "OLA_WATCHDOG_INTERVAL must be at least 10 seconds."
  [[ "$WATCHDOG_FAILURES" -ge 1 ]] || die "OLA_WATCHDOG_FAILURES must be at least 1."
  [[ "$WATCHDOG_COOLDOWN" -ge 10 ]] || die "OLA_WATCHDOG_COOLDOWN must be at least 10 seconds."
  trap 'exit 0' TERM INT
  watchdog_log "started (interval=${WATCHDOG_INTERVAL}s failures=${WATCHDOG_FAILURES} cooldown=${WATCHDOG_COOLDOWN}s)"
  watchdog_sleep "$WATCHDOG_INTERVAL"
  while true; do
    if [[ -f "$SUP_DIR/ollama.conf" ]] && supervisor_program_running ollama; then
      if ollama_api_ready; then
        ollama_failures=0
      else
        ollama_failures=$((ollama_failures + 1))
        watchdog_log "Ollama API failed health check ${ollama_failures}/${WATCHDOG_FAILURES}."
        if [[ "$ollama_failures" -ge "$WATCHDOG_FAILURES" ]]; then
          watchdog_log "restarting Ollama after repeated API failures."
          supervisor_ctl restart ollama || watchdog_log "ERROR: Supervisor could not restart Ollama."
          ollama_failures=0
          watchdog_sleep "$WATCHDOG_COOLDOWN"
          continue
        fi
      fi
    else
      ollama_failures=0
    fi

    if [[ -f "$SUP_DIR/cloudflared-ollama.conf" ]] && supervisor_program_running cloudflared-ollama; then
      state=0
      cloudflared_ready_state || state=$?
      if [[ "$state" -eq 0 ]]; then
        cloudflared_failures=0
      elif [[ "$state" -eq 1 ]]; then
        cloudflared_failures=$((cloudflared_failures + 1))
        watchdog_log "cloudflared failed readiness check ${cloudflared_failures}/${WATCHDOG_FAILURES}."
        if [[ "$cloudflared_failures" -ge "$WATCHDOG_FAILURES" ]]; then
          watchdog_log "restarting cloudflared after repeated readiness failures."
          supervisor_ctl restart cloudflared-ollama || watchdog_log "ERROR: Supervisor could not restart cloudflared."
          cloudflared_failures=0
          watchdog_sleep "$WATCHDOG_COOLDOWN"
          continue
        fi
      else
        cloudflared_failures=0
      fi
    else
      cloudflared_failures=0
    fi
    watchdog_sleep "$WATCHDOG_INTERVAL"
  done
}

show_watchdog(){
  select_supervisor_paths
  echo "--- Health watchdog ---"
  if [[ -f "$SUP_DIR/ollama-watchdog.conf" ]]; then
    echo "Config: $SUP_DIR/ollama-watchdog.conf"
  else
    echo "Not installed yet. Run: ola start (or a full setup)."
    return 0
  fi
  if command -v supervisorctl >/dev/null 2>&1 && [[ -f "$SUP_CONF" ]]; then
    supervisor_ctl status ollama-watchdog 2>/dev/null || echo "ollama-watchdog is not RUNNING."
  else
    echo "Supervisor is not installed/configured yet."
  fi
  local f
  for f in "$LOG_DIR/ollama-watchdog.log" "$LOG_DIR/ollama-watchdog-error.log"; do
    if [[ -r "$f" ]]; then
      echo "===== $f ====="
      tail -n 30 "$f"
    elif [[ -f "$f" ]]; then
      echo "===== $f ====="
      echo "Not readable by this user (run watchdog as root)."
    fi
  done
}

show_doctor(){
  local failures=0 warnings=0 cmd program version_json ollama_version tags_json ps_json model_names loaded_names
  local model home_dir mem_kb disk_kb log_bytes public_url state validate_output
  select_supervisor_paths
  echo "--- Ola doctor ---"

  for cmd in curl jq supervisorctl supervisord; do
    if command -v "$cmd" >/dev/null 2>&1; then
      ok "$cmd found"
    else
      err "$cmd not found"
      failures=$((failures + 1))
    fi
  done
  if ollama_bin_path >/dev/null 2>&1; then
    ok "Ollama binary found: $(ollama_bin_path)"
  else
    err "Ollama binary not found"
    failures=$((failures + 1))
  fi
  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared found: $(cloudflared --version 2>&1 | head -n 1)"
  else
    err "cloudflared binary not found"
    failures=$((failures + 1))
  fi

  if [[ -f "$SUP_CONF" ]]; then
    ok "Supervisor config: $SUP_CONF"
  else
    err "Supervisor config not found: $SUP_CONF"
    failures=$((failures + 1))
  fi
  if supervisor_is_running; then
    ok "Supervisor is responding"
  else
    err "Supervisor is not responding (try: ola recover)"
    failures=$((failures + 1))
  fi

  for program in ollama cloudflared-ollama; do
    if supervisor_program_running "$program"; then
      ok "$program is RUNNING"
    else
      err "$program is not RUNNING (try: ola recover)"
      failures=$((failures + 1))
    fi
  done
  if [[ -f "$SUP_DIR/ollama-watchdog.conf" ]]; then
    if supervisor_program_running ollama-watchdog; then
      ok "ollama-watchdog is RUNNING"
    else
      warn "ollama-watchdog is configured but not RUNNING (try: ola start)"
      warnings=$((warnings + 1))
    fi
  else
    warn "Health watchdog is not installed yet (run: ola start)"
    warnings=$((warnings + 1))
  fi

  version_json=$(curl -fsS --max-time 10 http://127.0.0.1:11434/api/version 2>/dev/null || true)
  if [[ -n "$version_json" ]]; then
    ollama_version=""
    if command -v jq >/dev/null 2>&1; then
      ollama_version=$(printf '%s' "$version_json" | jq -r '.version // empty' 2>/dev/null || true)
    fi
    [[ -n "$ollama_version" ]] || ollama_version="$version_json"
    ok "Ollama local API: $ollama_version"
  else
    err "Ollama local API is not answering on 127.0.0.1:11434"
    failures=$((failures + 1))
  fi

  model=$(saved_model_name)
  home_dir=$(ollama_home_for_status)
  tags_json=$(curl -fsS --max-time 10 http://127.0.0.1:11434/api/tags 2>/dev/null || true)
  model_names=""
  loaded_names=""
  if [[ -n "$tags_json" ]]; then
    if command -v jq >/dev/null 2>&1; then
      model_names=$(printf '%s' "$tags_json" | jq -r '.models[]?.name // empty' 2>/dev/null || true)
      ps_json=$(curl -fsS --max-time 10 http://127.0.0.1:11434/api/ps 2>/dev/null || true)
      loaded_names=$(printf '%s' "$ps_json" | jq -r '.models[]?.name // empty' 2>/dev/null || true)
    else
      model_names=$(printf '%s' "$tags_json" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)
    fi
  fi
  if [[ -n "$model_names" ]]; then
    ok "Installed models: $(printf '%s' "$model_names" | tr '\n' ' ')"
    if printf '%s\n' "$model_names" | grep -Fxq "$model"; then
      ok "Default model is installed: $model"
    else
      err "Default model is not installed: $model"
      failures=$((failures + 1))
    fi
  elif [[ -n "$version_json" ]]; then
    warn "Could not list installed Ollama models"
    warnings=$((warnings + 1))
  fi
  if [[ -n "$loaded_names" ]]; then
    ok "Currently loaded: $(printf '%s' "$loaded_names" | tr '\n' ' ')"
  else
    info "No model currently loaded (it will load on the next request)."
  fi

  if supervisor_program_running cloudflared-ollama; then
    state=0
    cloudflared_ready_state || state=$?
    if [[ "$state" -eq 0 ]]; then
      ok "cloudflared readiness endpoint reports ready"
    elif [[ "$state" -eq 1 ]]; then
      err "cloudflared is RUNNING but reports not ready"
      failures=$((failures + 1))
    else
      warn "cloudflared readiness endpoint unavailable; readiness is unknown"
      warnings=$((warnings + 1))
    fi
  fi

  if [[ -f "$CF_CONF_DIR/config.yml" ]] && command -v cloudflared >/dev/null 2>&1; then
    if validate_output=$(cloudflared tunnel --config "$CF_CONF_DIR/config.yml" ingress validate 2>&1); then
      ok "Cloudflare ingress config is valid"
    else
      warn "Cloudflare ingress validation did not pass: $validate_output"
      warnings=$((warnings + 1))
    fi
  fi

  mem_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    if [[ "$mem_kb" -lt 524288 ]]; then
      warn "Available RAM is low: about $((mem_kb / 1024)) MB"
      warnings=$((warnings + 1))
    else
      ok "Available RAM: about $((mem_kb / 1024)) MB"
    fi
  else
    warn "Could not determine available RAM"
    warnings=$((warnings + 1))
  fi

  disk_kb=$(free_kb "$home_dir")
  if [[ "$disk_kb" -gt 0 && "$disk_kb" -lt 1048576 ]]; then
    warn "Free disk space on $home_dir is low: about $((disk_kb / 1024)) MB"
    warnings=$((warnings + 1))
  elif [[ "$disk_kb" -gt 0 ]]; then
    ok "Free disk space on $home_dir: about $((disk_kb / 1024)) MB"
  fi

  log_bytes=0
  local f size
  for f in "$LOG_DIR"/*.log; do
    [[ -f "$f" ]] || continue
    size=$(file_size "$f")
    log_bytes=$((log_bytes + size))
  done
  ok "Supervisor logs currently use about $((log_bytes / 1024 / 1024)) MB (rotation is enabled)."

  if [[ -r "$URL_FILE" ]]; then
    public_url=$(head -n 1 "$URL_FILE")
    if [[ -n "$public_url" ]]; then
      if https_url_ready "${public_url}/api/version"; then
        ok "Public URL answers: $public_url"
      else
        err "Public URL does not answer yet: $public_url"
        failures=$((failures + 1))
      fi
    else
      warn "Public URL file is empty: $URL_FILE"
      warnings=$((warnings + 1))
    fi
  elif [[ -f "$URL_FILE" ]]; then
    warn "Public URL is saved but is not readable by this user"
    warnings=$((warnings + 1))
  else
    warn "No public URL saved yet"
    warnings=$((warnings + 1))
  fi

  echo "--- Doctor summary: ${failures} failure(s), ${warnings} warning(s) ---"
  [[ "$failures" -eq 0 ]]
}

run_ola_test(){
  local failures=0 model version_json tags_json model_names payload response content public_url
  local start_ms end_ms elapsed_ms
  model=$(saved_model_name)
  echo "--- Ola test ---"
  info "Default model: $model"

  start_ms=$(date +%s%3N)
  if version_json=$(curl -fsS --max-time 15 http://127.0.0.1:11434/api/version 2>/dev/null); then
    end_ms=$(date +%s%3N)
    elapsed_ms=$((end_ms - start_ms))
    ok "Local Ollama API: $version_json (${elapsed_ms} ms)"
  else
    err "Local Ollama API failed"
    failures=$((failures + 1))
    echo "--- Test summary: FAILED ---"
    return 1
  fi

  if tags_json=$(curl -fsS --max-time 15 http://127.0.0.1:11434/api/tags 2>/dev/null); then
    model_names=""
    if command -v jq >/dev/null 2>&1; then
      model_names=$(printf '%s' "$tags_json" | jq -r '.models[]?.name // empty' 2>/dev/null || true)
    else
      model_names=$(printf '%s' "$tags_json" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)
    fi
    if printf '%s\n' "$model_names" | grep -Fxq "$model"; then
      ok "Model is installed: $model"
    else
      err "Model is not installed: $model"
      failures=$((failures + 1))
    fi
  else
    err "Could not list Ollama models"
    failures=$((failures + 1))
  fi

  if command -v jq >/dev/null 2>&1; then
    payload=$(jq -cn --arg model "$model" '{model:$model, messages:[{role:"user", content:"Reply only with OK."}], stream:false}')
    start_ms=$(date +%s%3N)
    if response=$(curl -fsS --max-time 180 http://127.0.0.1:11434/api/chat -H 'Content-Type: application/json' -d "$payload" 2>/dev/null); then
      end_ms=$(date +%s%3N)
      elapsed_ms=$((end_ms - start_ms))
      content=$(printf '%s' "$response" | jq -r '.message.content // .response // empty' 2>/dev/null || true)
      [[ -n "$content" ]] || content="(empty response)"
      ok "Local chat test (${elapsed_ms} ms): $content"
    else
      err "Local chat test failed for model: $model"
      failures=$((failures + 1))
    fi
  else
    err "jq is required for the chat test"
    failures=$((failures + 1))
  fi

  if [[ -r "$URL_FILE" ]]; then
    public_url=$(head -n 1 "$URL_FILE")
    if [[ -n "$public_url" ]] && https_url_ready "${public_url}/api/version"; then
      ok "Public API answers: $public_url"
    else
      err "Public API does not answer: ${public_url:-unknown}"
      failures=$((failures + 1))
    fi
  else
    err "No readable public URL saved"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    ok "All tests passed."
  else
    err "Test summary: ${failures} failure(s)."
  fi
  [[ "$failures" -eq 0 ]]
}

recover_services(){
  local want_ollama=0 want_cloudflared=0 state
  select_supervisor_paths
  [[ -f "$SUP_DIR/ollama.conf" ]] && want_ollama=1
  [[ -f "$SUP_DIR/cloudflared-ollama.conf" ]] && want_cloudflared=1
  if [[ "$want_ollama" -eq 0 && "$want_cloudflared" -eq 0 ]]; then
    die "No Ollama/cloudflared Supervisor programs are configured. Run setup first: ola setup"
  fi

  if [[ "$want_ollama" -eq 1 ]]; then
    if ! supervisor_program_running ollama; then
      info "Ollama is not RUNNING; starting it..."
      supervisor_ctl start ollama 2>/dev/null || supervisor_ctl restart ollama \
        || die "Could not start Ollama. Check: ola logs"
    fi
    wait_for_supervisor_program ollama 30 \
      || die "Ollama did not reach RUNNING during recover. Check: ola logs"
    if ! ollama_api_ready; then
      warn "Ollama is RUNNING but its API is not answering; restarting Ollama once..."
      supervisor_ctl restart ollama || die "Could not restart Ollama during recover."
      wait_for_supervisor_program ollama 30 \
        || die "Ollama did not reach RUNNING after recover restart."
      ollama_api_ready || die "Ollama API still does not answer after recover. Check: ola logs"
    fi
    ok "Ollama recovered and answering locally."
  fi

  if [[ "$want_cloudflared" -eq 1 ]]; then
    if ! supervisor_program_running cloudflared-ollama; then
      info "cloudflared-ollama is not RUNNING; starting it..."
      supervisor_ctl start cloudflared-ollama 2>/dev/null || supervisor_ctl restart cloudflared-ollama \
        || die "Could not start cloudflared. Check: ola logs"
    fi
    wait_for_supervisor_program cloudflared-ollama 30 \
      || die "cloudflared did not reach RUNNING during recover. Check: ola logs"
    state=0
    wait_cloudflared_ready 30 || state=$?
    if [[ "$state" -eq 1 ]]; then
      warn "cloudflared reports not ready; restarting it once..."
      supervisor_ctl restart cloudflared-ollama || die "Could not restart cloudflared during recover."
      wait_for_supervisor_program cloudflared-ollama 30 \
        || die "cloudflared did not reach RUNNING after recover restart."
      state=0
      wait_cloudflared_ready 60 || state=$?
      [[ "$state" -eq 1 ]] && die "cloudflared still reports not ready after recover. Check: ola logs"
    fi
    if [[ "$state" -eq 2 ]]; then
      warn "cloudflared is RUNNING; readiness endpoint was unavailable, so no restart was forced."
    else
      ok "cloudflared recovered and ready."
    fi
  fi

  echo
  show_status
  ok "Recover finished."
}

setup_all(){
  case "$CF_TUNNEL_PROTOCOL" in
    auto|http2|quic) ;;
    *) die "Invalid CF_TUNNEL_PROTOCOL='$CF_TUNNEL_PROTOCOL' (expected auto, http2 or quic)." ;;
  esac
  install_ola_command
  apt_update
  apt_install curl ca-certificates gnupg jq tar
  require_commands curl jq sha256sum tar awk sed grep find stat df
  ensure_service_users
  ensure_supervisor_running
  ensure_watchdog
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
  ok "Setup finished. Try: ola doctor, ola test, ola recover, ola logs"
  warn "Supervisor can restart processes, but 24/7 uptime still depends on the hosting platform keeping this container alive and starting Supervisor again after container restart."
}

case "${1:-}" in
  --help|-h|help)
    usage
    ;;
  status)
    show_status
    ;;
  doctor)
    show_doctor
    ;;
  test)
    run_ola_test
    ;;
  use)
    require_root
    if [[ -z "${2:-}" ]]; then
      err "Usage: ola use <model> (example: ola use llama3.2:1b)"
      exit 1
    fi
    install_ola_command
    require_supervisor_running
    ensure_watchdog
    switch_model "$2"
    ;;
  ps)
    show_loaded_models
    ;;
  unload)
    require_root
    install_ola_command
    require_supervisor_running
    ensure_watchdog
    unload_models_command "${2:-}"
    ;;
  watchdog)
    show_watchdog
    ;;
  watchdog-daemon)
    require_root
    run_watchdog_daemon
    ;;
  recover)
    require_root
    install_ola_command
    require_supervisor_running
    ensure_watchdog
    recover_services
    ;;
  logs)
    show_logs
    ;;
  setup)
    require_root
    check_system
    setup_all
    ;;
  start|restart)
    require_root
    install_ola_command
    require_supervisor_running
    ensure_watchdog
    restart_services
    ;;
  stop)
    require_root
    install_ola_command
    require_supervisor_running
    stop_tunnel
    ;;
  "")
    echo "===================================="
    echo " Ollama + Cloudflare Tunnel Manager"
    echo "===================================="
    echo "1) Full setup (Ollama + model + tunnel)"
    echo "2) Status"
    echo "3) Doctor (full diagnostic)"
    echo "4) Test API + model"
    echo "5) Show logs"
    echo "6) Start/restart Ollama and tunnel"
    echo "7) Recover stopped/unhealthy services"
    echo "8) Use another model (unload current from RAM first)"
    echo "9) Unload loaded model(s) from RAM"
    echo "10) Watchdog status"
    echo "11) Stop tunnel"
    echo "12) Exit"
    if ! choice=$(prompt_value "Choice [12]: " "12"); then
      warn "No input received; exiting."
      exit 0
    fi
    case "$choice" in
      1) require_root; check_system; setup_all ;;
      2) show_status ;;
      3) show_doctor ;;
      4) run_ola_test ;;
      5) show_logs ;;
      6) require_root; install_ola_command; require_supervisor_running; ensure_watchdog; restart_services ;;
      7) require_root; install_ola_command; require_supervisor_running; ensure_watchdog; recover_services ;;
      8)
        require_root
        install_ola_command
        require_supervisor_running
        ensure_watchdog
        if ! model_choice=$(prompt_value "Model to use (example llama3.2:1b): " ""); then
          die "No model received; cancelling model switch."
        fi
        switch_model "$model_choice"
        ;;
      9)
        require_root
        install_ola_command
        require_supervisor_running
        ensure_watchdog
        if ! model_choice=$(prompt_value "Model to unload (blank = all loaded): " ""); then
          die "No input received; cancelling unload."
        fi
        unload_models_command "$model_choice"
        ;;
      10) show_watchdog ;;
      11) require_root; install_ola_command; require_supervisor_running; stop_tunnel ;;
      12) exit 0 ;;
      *) die "Invalid choice." ;;
    esac
    ;;
  *)
    err "Unknown argument: $1 (use --help)."
    usage >&2
    exit 1
    ;;
esac
