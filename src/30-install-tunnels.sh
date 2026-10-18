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
  write_ollama_supervisor_config "$ollama_bin" "$(saved_speed_mode)"
  if [[ "$(saved_speed_mode)" == "speed" ]]; then
    info "Pack Speed is enabled for Ollama (Flash Attention + q8_0 KV cache; context and parallel requests unchanged)."
  fi
  if [[ "$(saved_keep_alive)" != "5m" ]]; then
    info "Fluid keep-alive default is kept: OLLAMA_KEEP_ALIVE=$(saved_keep_alive) (saved in $KEEPALIVE_FILE)."
  fi

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

  local model=${1:-}
  if [[ -z "$model" ]]; then
    if ! model=$(prompt_value "Ollama model [$MODEL_DEFAULT]: " "$MODEL_DEFAULT"); then
      die "No input received for the Ollama model; aborting instead of silently using the default."
    fi
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
  local preset=${2:-0} tunnel_name="ollama-vps" hostname=${1:-} uuid source_cred cred_file protocol_line="" candidate_home alt_home
  echo ""
  warn "This mode uses your Cloudflare account and a domain/subdomain. It does not configure Cloudflare Access."
  if [[ "$preset" == "1" ]]; then
    if [[ -n "$hostname" ]]; then
      hostname="${hostname,,}"
      is_valid_hostname "$hostname" || die "Invalid hostname."
      info "Named Tunnel preset: tunnel name '$tunnel_name', hostname '$hostname'."
    else
      if ! hostname=$(prompt_value "Public hostname (e.g. ollama.example.com): " ""); then
        die "No input received for the public hostname; aborting."
      fi
      hostname="${hostname,,}"
      is_valid_hostname "$hostname" || die "Invalid hostname."
      info "Named Tunnel preset: tunnel name '$tunnel_name'."
    fi
  else
    if ! tunnel_name=$(prompt_value "Tunnel name [ollama-vps]: " "ollama-vps"); then
      die "No input received for the tunnel name; aborting."
    fi
    [[ "$tunnel_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "$tunnel_name" != *".."* ]] || die "Invalid tunnel name."
    if ! hostname=$(prompt_value "Public hostname (e.g. ollama.example.com): " ""); then
      die "No input received for the public hostname; aborting."
    fi
    hostname="${hostname,,}"
    is_valid_hostname "$hostname" || die "Invalid hostname."
  fi

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
