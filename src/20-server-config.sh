# Pack Speed mode is persisted in SPEED_FILE ("balanced" or "speed") so a
# later setup keeps the choice. "balanced" is exactly the historical
# configuration. "speed" only adds Flash Attention and a q8_0 KV cache; it
# deliberately never raises OLLAMA_NUM_PARALLEL, OLLAMA_MAX_LOADED_MODELS or
# the context length, which would cost RAM on small sandboxes.
saved_speed_mode(){
  local mode=""
  if [[ -r "$SPEED_FILE" ]]; then
    mode=$(head -n 1 "$SPEED_FILE" 2>/dev/null || true)
  fi
  case "$mode" in
    speed) printf '%s' "speed" ;;
    *) printf '%s' "balanced" ;;
  esac
}

save_speed_mode(){
  local mode=$1
  printf '%s\n' "$mode" > "$SPEED_FILE" || die "Could not save the speed mode to $SPEED_FILE."
  chmod 600 "$SPEED_FILE" || die "Could not set permissions on $SPEED_FILE."
}

# Server-wide OLLAMA_KEEP_ALIVE default, persisted in KEEPALIVE_FILE so a
# later setup keeps the choice. "5m" is exactly Ollama's historical default
# and frees RAM sooner; a longer value keeps one model warm (faster first
# token) but holds its RAM. Only applied to the Supervisor config by
# "ola fluid keepalive"; it never raises the model/parallel counts.
is_valid_keep_alive(){
  local value=$1
  [[ -n "$value" ]] || return 1
  [[ "$value" == "-1" ]] && return 0
  [[ "$value" =~ ^[0-9]+$ ]] && return 0
  [[ "$value" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ ]]
}

saved_keep_alive(){
  local value=""
  if [[ -r "$KEEPALIVE_FILE" ]]; then
    value=$(head -n 1 "$KEEPALIVE_FILE" 2>/dev/null || true)
  fi
  if is_valid_keep_alive "$value"; then
    printf '%s' "$value"
  else
    printf '%s' "5m"
  fi
}

save_keep_alive(){
  local value=$1
  printf '%s\n' "$value" > "$KEEPALIVE_FILE" || die "Could not save the keep-alive default to $KEEPALIVE_FILE."
  chmod 600 "$KEEPALIVE_FILE" || die "Could not set permissions on $KEEPALIVE_FILE."
}

# Paths interpolated into the Supervisor environment line must not be able
# to break out of their quoted value or smuggle in another environment
# assignment. Reject quotes, backslashes, commas and line breaks rather than
# trying to escape a format that has no safe general escaping rule here.
is_safe_service_path(){
  local value=$1
  [[ -n "$value" && "$value" == /* ]] || return 1
  case "$value" in
    *\"*|*\\*|*,*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

saved_ollama_models_dir(){
  if [[ -n "${OLLAMA_MODELS_DIR:-}" ]]; then
    printf '%s' "$OLLAMA_MODELS_DIR"
    return 0
  fi
  ollama_config_value OLLAMA_MODELS
}

ensure_ollama_models_dir(){
  local models_dir
  models_dir=$(saved_ollama_models_dir)
  [[ -n "$models_dir" ]] || return 0
  is_safe_service_path "$models_dir" \
    || die "Unsafe Ollama models directory: $models_dir (expected an absolute path without quotes, backslashes, commas or line breaks)."
  if is_colab_mode; then
    # Google Drive FUSE does not provide reliable Unix ownership/mode changes.
    # The Colab service runs as root, so plain directory creation is enough.
    mkdir -p "$models_dir" \
      || die "Could not create the Ollama models directory: $models_dir"
  else
    install -d -o "$OLLAMA_USER" -g "$OLLAMA_GROUP" -m 0755 "$models_dir" \
      || die "Could not create the Ollama models directory: $models_dir"
  fi
}

colab_gpu_library_path(){
  # Only the fixed Colab/NVIDIA locations are trusted in the root service
  # environment. Never propagate an inherited LD_LIBRARY_PATH into the
  # Supervisor configuration: a caller-supplied search path would control
  # which shared libraries the Ollama service loads.
  printf '%s' "/usr/lib64-nvidia:/usr/local/cuda/lib64"
}

ollama_environment_line(){
  local mode=$1 env models_dir
  is_valid_context_length "$OLLAMA_CONTEXT_LENGTH" \
    || die "Invalid OLLAMA_CONTEXT_LENGTH='$OLLAMA_CONTEXT_LENGTH' (expected a positive integer)."
  is_safe_service_path "$OLLAMA_HOME" \
    || die "Unsafe Ollama service home path: $OLLAMA_HOME"
  env="OLLAMA_HOST=\"127.0.0.1:11434\",OLLAMA_ORIGINS=\"*\",OLLAMA_CONTEXT_LENGTH=\"$OLLAMA_CONTEXT_LENGTH\",OLLAMA_KEEP_ALIVE=\"$(saved_keep_alive)\",OLLAMA_MAX_LOADED_MODELS=\"1\",OLLAMA_NUM_PARALLEL=\"1\",OLLAMA_MAX_QUEUE=\"$OLLAMA_MAX_QUEUE\""
  if [[ "$mode" == "speed" ]]; then
    env="${env},OLLAMA_FLASH_ATTENTION=\"1\",OLLAMA_KV_CACHE_TYPE=\"q8_0\""
  fi
  models_dir=$(saved_ollama_models_dir)
  if [[ -n "$models_dir" ]]; then
    is_safe_service_path "$models_dir" \
      || die "Unsafe Ollama models directory: $models_dir (expected an absolute path without quotes, backslashes, commas or line breaks)."
    env="${env},OLLAMA_MODELS=\"$models_dir\""
  fi
  if is_colab_mode; then
    env="${env},LD_LIBRARY_PATH=\"$(colab_gpu_library_path)\""
  fi
  env="${env},HOME=\"$OLLAMA_HOME\""
  printf '%s' "$env"
}

write_ollama_supervisor_config(){
  local ollama_bin=$1 mode=$2 env_line
  env_line=$(ollama_environment_line "$mode")
  cat > "$SUP_DIR/ollama.conf" <<EOF
[program:ollama]
command=$ollama_bin serve
user=$OLLAMA_USER
environment=$env_line
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
}

# Reads one OLLAMA_* value from the generated Supervisor config. Prints an
# empty string when the file or the key is unavailable (for example when a
# non-root user cannot read the root-only config file).
ollama_config_value(){
  local key=$1 file="$SUP_DIR/ollama.conf" line
  [[ -r "$file" ]] || return 0
  line=$(grep '^environment=' "$file" 2>/dev/null | head -n 1 || true)
  [[ -n "$line" ]] || return 0
  printf '%s' "$line" | tr ',' '\n' | sed -n "s/^${key}=\"\\(.*\\)\"$/\\1/p" | head -n 1
}

speed_config_matches(){
  local mode=$1 flash
  [[ -r "$SUP_DIR/ollama.conf" ]] || return 1
  flash=$(ollama_config_value OLLAMA_FLASH_ATTENTION)
  if [[ "$mode" == "speed" ]]; then
    [[ "$flash" == "1" ]] || return 1
    [[ "$(ollama_config_value OLLAMA_KV_CACHE_TYPE)" == "q8_0" ]] || return 1
  else
    [[ -z "$flash" ]] || return 1
    [[ -z "$(ollama_config_value OLLAMA_KV_CACHE_TYPE)" ]] || return 1
  fi
  return 0
}

cpu_logical_cores(){
  local n
  n=$(nproc 2>/dev/null || printf '%s' "1")
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] || n=1
  printf '%s' "$n"
}

cpu_physical_cores(){
  local logical per sockets cores
  logical=$(cpu_logical_cores)
  per=""
  sockets=""
  if command -v lscpu >/dev/null 2>&1; then
    per=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket:/ { v=$2; gsub(/[[:space:]]/, "", v); print v; exit }')
    sockets=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\):/ { v=$2; gsub(/[[:space:]]/, "", v); print v; exit }')
  fi
  if [[ "$per" =~ ^[0-9]+$ && "$sockets" =~ ^[0-9]+$ ]]; then
    cores=$((per * sockets))
    if [[ "$cores" -ge 1 && "$cores" -le "$logical" ]]; then
      printf '%s' "$cores"
      return 0
    fi
  fi
  per=$(awk -F: '/^cpu cores/ { v=$2; gsub(/[[:space:]]/, "", v); print v; exit }' /proc/cpuinfo 2>/dev/null || true)
  if [[ "$per" =~ ^[0-9]+$ && "$per" -ge 1 && "$per" -le "$logical" ]]; then
    printf '%s' "$per"
    return 0
  fi
  printf '%s' "$logical"
}

cpu_speed_summary(){
  local flags
  flags=$(awk -F: '/^flags/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || true)
  case " $flags " in
    *" avx512f "*) printf '%s' "AVX-512 détecté (meilleur backend CPU Ollama attendu)" ;;
    *" avx2 "*) printf '%s' "AVX2 détecté (bon backend CPU Ollama : cpu_avx2)" ;;
    *" avx "*) printf '%s' "AVX détecté, sans AVX2 (backend CPU Ollama intermédiaire)" ;;
    *) printf '%s' "ni AVX2 ni AVX détectés (backend CPU générique, plus lent)" ;;
  esac
}
