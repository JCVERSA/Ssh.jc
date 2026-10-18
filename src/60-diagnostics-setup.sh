show_doctor(){
  local failures=0 warnings=0 cmd program version_json ollama_version tags_json ps_json model_names loaded_names
  local model home_dir mem_kb disk_kb log_bytes public_url state validate_output speed_flash speed_kv speed_keepalive tui_version
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

  if tui_environment_ready; then
    tui_version=$(tui_textual_version)
    ok "Textual TUI installed: Textual $tui_version (launch: ola tui)"
  else
    warn "Textual TUI is not installed/ready (classic ola commands still work; repair: sudo ola tui install)"
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

  speed_flash=$(ollama_config_value OLLAMA_FLASH_ATTENTION)
  speed_kv=$(ollama_config_value OLLAMA_KV_CACHE_TYPE)
  speed_keepalive=$(ollama_config_value OLLAMA_KEEP_ALIVE)
  info "Speed mode: $(saved_speed_mode) (Flash Attention: ${speed_flash:-off}, KV cache: ${speed_kv:-default f16}) — details: ola speed, measure: ola bench"
  info "Fluid keep-alive: saved $(saved_keep_alive), effective ${speed_keepalive:-unknown} — details: ola fluid, streaming measure: ola bench --stream"

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
  if ! install_tui_environment; then
    warn "The optional Textual TUI could not be installed. Setup will continue: every classic ola command remains available, and the TUI can be repaired later with: sudo ola tui install"
  fi
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
