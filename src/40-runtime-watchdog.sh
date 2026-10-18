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

wait_for_ollama_api(){
  local seconds=$1 i
  for ((i=1; i<=seconds; i++)); do
    if ollama_api_ready; then
      return 0
    fi
    sleep 1
  done
  return 1
}
