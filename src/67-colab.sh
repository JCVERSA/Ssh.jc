# Google Colab persistence helpers.
#
# Colab runtimes are disposable VMs. The notebook mounts Google Drive and
# passes OLA_COLAB=1 plus OLA_COLAB_STATE_DIR=/content/drive/MyDrive/ola-colab.
# In that profile (and only in that profile) Ollama/cloudflared run as root so
# they can use the notebook user's Drive FUSE mount and NVIDIA devices. Normal
# VPS/sandbox installs keep the dedicated ollama/cloudflared users.
#
# What can honestly persist between Colab runtimes:
#   - Ollama model blobs, by pointing OLLAMA_MODELS at the Drive state dir;
#   - the small ola settings files (default model, Pack Speed, keep-alive);
#   - a record of the last Quick Tunnel URL (informational only).
# What cannot persist: installed binaries, /etc configuration, Supervisor
# processes and the Quick Tunnel URL itself. A new runtime must re-run the
# notebook; setup recreates the system side and restores the Drive state.

colab_write_runtime_marker(){
  is_colab_mode || return 0
  printf 'mode=colab\n%s\n' "${OLA_COLAB_STATE_DIR:-}" > "$COLAB_RUNTIME_FILE" || return 1
  chmod 600 "$COLAB_RUNTIME_FILE" 2>/dev/null || true
}

colab_state_restore(){
  is_colab_mode || return 0
  local state_dir=${OLA_COLAB_STATE_DIR:-} config_dir src dst
  [[ -n "$state_dir" ]] || return 0
  case "$state_dir" in
    /*) ;;
    *) warn "OLA_COLAB_STATE_DIR doit être un chemin absolu : $state_dir"; return 1 ;;
  esac
  config_dir="$state_dir/config"
  mkdir -p "$config_dir" "$state_dir/models" || return 1
  if [[ -z "${OLLAMA_MODELS_DIR:-}" ]]; then
    OLLAMA_MODELS_DIR="$state_dir/models"
  fi
  for dst in "$MODEL_FILE" "$SPEED_FILE" "$KEEPALIVE_FILE"; do
    src="$config_dir/$(basename "$dst")"
    if [[ -f "$src" ]]; then
      cp -f "$src" "$dst" || return 1
    fi
  done
  colab_write_runtime_marker || return 1
  info "État Colab restauré depuis $state_dir (modèles : $OLLAMA_MODELS_DIR)."
}

colab_state_save(){
  is_colab_mode || return 0
  local state_dir=${OLA_COLAB_STATE_DIR:-} config_dir src
  [[ -n "$state_dir" ]] || return 0
  case "$state_dir" in
    /*) ;;
    *) warn "OLA_COLAB_STATE_DIR doit être un chemin absolu : $state_dir"; return 1 ;;
  esac
  config_dir="$state_dir/config"
  mkdir -p "$config_dir" "$state_dir/models" || return 1
  for src in "$MODEL_FILE" "$SPEED_FILE" "$KEEPALIVE_FILE"; do
    if [[ -f "$src" ]]; then
      cp -f "$src" "$config_dir/" || return 1
    fi
  done
  if [[ -f "$URL_FILE" ]]; then
    cp -f "$URL_FILE" "$config_dir/ollama-cloudflare-last-url" || return 1
  fi
  colab_write_runtime_marker || return 1
  info "État Colab sauvegardé dans $state_dir (la prochaine URL Quick Tunnel sera nouvelle)."
}

colab_restore_command(){
  is_colab_mode || die "Mode Colab inactif. Dans Colab, lance le notebook ou définis OLA_COLAB=1 avant cette commande."
  [[ -n "${OLA_COLAB_STATE_DIR:-}" ]] || die "OLA_COLAB_STATE_DIR n'est pas défini ; aucun état Colab à restaurer."
  colab_state_restore || die "Impossible de restaurer l'état Colab depuis ${OLA_COLAB_STATE_DIR}."
  warn "Réglages restaurés. Relance 'ola setup default' dans ce runtime pour régénérer les services avec ces réglages."
}

colab_save_command(){
  is_colab_mode || die "Mode Colab inactif. Dans Colab, lance le notebook ou définis OLA_COLAB=1 avant cette commande."
  [[ -n "${OLA_COLAB_STATE_DIR:-}" ]] || die "OLA_COLAB_STATE_DIR n'est pas défini ; aucun dossier Google Drive où sauvegarder."
  colab_state_save || die "Impossible de sauvegarder l'état Colab dans ${OLA_COLAB_STATE_DIR}."
}

show_colab_status(){
  local state_dir=${OLA_COLAB_STATE_DIR:-} models_dir gpu_lines public_url
  echo "--- Ola Colab ---"
  if is_colab_mode; then
    ok "Mode Colab : activé (profil runtime jetable, services en root)"
  else
    info "Mode Colab : inactif (profil standard VPS/sandbox, utilisateurs dédiés ollama/cloudflared)"
  fi
  echo "État persistant (Google Drive) : ${state_dir:-non configuré}"
  if [[ -n "$state_dir" ]]; then
    if [[ -d "$state_dir" ]]; then
      ok "Dossier d'état accessible : $state_dir"
    else
      warn "Dossier d'état pas encore créé/accessible : $state_dir (monte Google Drive puis relance le setup)."
    fi
  fi
  models_dir=$(saved_ollama_models_dir)
  echo "Dossier modèles Ollama : ${models_dir:-par défaut (HOME du service Ollama)}"
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu_lines=$(nvidia-smi -L 2>/dev/null || true)
    if [[ -n "$gpu_lines" ]]; then
      ok "GPU NVIDIA détecté :"
      printf '%s\n' "$gpu_lines" | sed 's/^/  /'
      echo "Bibliothèques NVIDIA exposées à Ollama : /usr/lib64-nvidia (configuration Supervisor en mode Colab)."
    else
      info "GPU NVIDIA : aucun détecté par nvidia-smi ; Ollama utilisera le CPU."
    fi
  else
    info "GPU NVIDIA : nvidia-smi absent ; Ollama utilisera le CPU."
  fi
  if [[ -r "$URL_FILE" ]]; then
    public_url=$(head -n 1 "$URL_FILE" 2>/dev/null || true)
    [[ -n "$public_url" ]] && echo "URL publique actuelle : $public_url"
  fi
  echo "Limites Colab : le runtime, les binaires, /etc et l'URL Quick Tunnel sont recréés à chaque nouveau runtime ; seuls les modèles et réglages dans Google Drive sont restaurés."
}

colab_command(){
  case "${1:-status}" in
    status)
      show_colab_status
      ;;
    save)
      require_root
      colab_save_command
      ;;
    restore)
      require_root
      colab_restore_command
      ;;
    *)
      err "Usage: ola colab [status|save|restore]"
      return 1
      ;;
  esac
}
