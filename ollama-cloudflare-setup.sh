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

info(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }

usage(){
  echo "Usage: bash $0 [setup|start|status|logs|restart|stop]"
  echo "No argument opens an interactive menu."
  echo "setup, restart and stop require root; status and logs are read-only."
  echo "After setup, the short system command is available: ola status | ola start | ola logs | ola stop"
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
  [[ -n "$model" ]] || die "Invalid empty Ollama model."
  local models_kb
  models_kb=$(free_kb "$OLLAMA_HOME")
  if [[ "$models_kb" -gt 0 && "$models_kb" -lt 2000000 ]]; then
    warn "Less than about 2 GB free on $OLLAMA_HOME. A larger model may fail while pulling; free disk space if needed."
  fi
  info "Pulling model $model (this may take a while)..."
  local pull_attempt
  for pull_attempt in 1 2; do
    if "$ollama_bin" pull "$model"; then
      break
    fi
    if [[ "$pull_attempt" -eq 2 ]]; then
      die "Failed to pull Ollama model: $model (check network, disk space and the exact model name)."
    fi
    warn "Model pull failed (attempt 1/2); retrying in 5 seconds..."
    sleep 5
  done
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
  ok "Setup finished. Logs: ola logs"
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
  start|restart)
    require_root
    install_ola_command
    require_supervisor_running
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
    echo "3) Show logs"
    echo "4) Start/restart Ollama and tunnel"
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
      4) require_root; install_ola_command; require_supervisor_running; restart_services ;;
      5) require_root; install_ola_command; require_supervisor_running; stop_tunnel ;;
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
