# Self-update for the installed ola manager.
#
# The installed command is a generated single-file artifact, not a Git
# checkout, so the equivalent of nebula-p's `manage.sh update` is:
# download the published artifact and its SHA-256 file, verify both, hand
# execution to the downloaded (new) code, let that code install itself
# atomically, restart the configured services, and restore the previous
# artifact if the post-install checks fail. Ollama/cloudflared binaries,
# models, saved settings and Supervisor configuration files are not replaced
# by this command; a full setup remains the way to regenerate those.

OLA_UPDATE_CANDIDATE=${OLA_UPDATE_CANDIDATE:-}
OLA_UPDATE_CHECKSUM_FILE=${OLA_UPDATE_CHECKSUM_FILE:-}
OLA_UPDATE_LOCK_OWNED=0
# Bound the self-update downloads so a redirected or malfunctioning endpoint
# cannot fill the installation filesystem before the SHA-256 check runs.
# The generated artifact is currently well under 1 MiB; 10 MiB leaves ample
# room for growth while still failing closed on an unbounded response.
OLA_UPDATE_MAX_ARTIFACT_BYTES=10485760
OLA_UPDATE_MAX_CHECKSUM_BYTES=4096

update_short_hash(){
  local hash=${1:-}
  if [[ -n "$hash" ]]; then
    printf '%s' "${hash:0:12}"
  else
    printf '%s' "absent"
  fi
}

update_file_sha256(){
  local file=$1
  [[ -f "$file" ]] || return 1
  sha256sum "$file" 2>/dev/null | awk 'NR == 1 { print tolower($1) }'
}

update_lock_held(){
  local pid="" mtime=0 now=0 age=0
  [[ -d "$OLA_UPDATE_LOCK_DIR" ]] || return 1
  if [[ -r "$OLA_UPDATE_LOCK_DIR/pid" ]]; then
    pid=$(head -n 1 "$OLA_UPDATE_LOCK_DIR/pid" 2>/dev/null || true)
  fi
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    warn "Verrou de mise à jour abandonné — nettoyage."
    rm -rf "$OLA_UPDATE_LOCK_DIR" 2>/dev/null || true
    return 1
  fi
  # A lock without a readable PID may still be in the middle of being
  # created by another process, so keep it briefly instead of racing it.
  mtime=$(stat -c %Y "$OLA_UPDATE_LOCK_DIR" 2>/dev/null || printf '%s' "0")
  now=$(date +%s 2>/dev/null || printf '%s' "0")
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  age=$((now - mtime))
  if [[ "$age" -ge 0 && "$age" -lt 60 ]]; then
    return 0
  fi
  warn "Verrou de mise à jour abandonné — nettoyage."
  rm -rf "$OLA_UPDATE_LOCK_DIR" 2>/dev/null || true
  return 1
}

update_lock_acquire(){
  local pid=""
  install -d -m 0755 "$OLA_INSTALL_DIR" \
    || die "Impossible de créer $OLA_INSTALL_DIR pour la mise à jour."
  if [[ -r "$OLA_UPDATE_LOCK_DIR/pid" ]]; then
    pid=$(head -n 1 "$OLA_UPDATE_LOCK_DIR/pid" 2>/dev/null || true)
    if [[ "$pid" == "$$" ]]; then
      OLA_UPDATE_LOCK_OWNED=1
      return 0
    fi
  fi
  if update_lock_held; then
    pid=""
    [[ -r "$OLA_UPDATE_LOCK_DIR/pid" ]] && pid=$(head -n 1 "$OLA_UPDATE_LOCK_DIR/pid" 2>/dev/null || true)
    die "Une mise à jour de ola est déjà en cours (PID ${pid:-inconnu}). Réessaie dans quelques minutes."
  fi
  mkdir "$OLA_UPDATE_LOCK_DIR" 2>/dev/null \
    || die "Une mise à jour de ola est déjà en cours. Réessaie dans quelques minutes."
  printf '%s\n' "$$" > "$OLA_UPDATE_LOCK_DIR/pid" \
    || die "Impossible d'écrire le verrou de mise à jour."
  date -Is > "$OLA_UPDATE_LOCK_DIR/since" 2>/dev/null || true
  OLA_UPDATE_LOCK_OWNED=1
}

update_lock_release(){
  if [[ "$OLA_UPDATE_LOCK_OWNED" -eq 1 ]]; then
    rm -rf "$OLA_UPDATE_LOCK_DIR" 2>/dev/null || true
    OLA_UPDATE_LOCK_OWNED=0
  fi
}

update_cleanup_files(){
  if [[ -n "$OLA_UPDATE_CANDIDATE" && -f "$OLA_UPDATE_CANDIDATE" ]]; then
    rm -f "$OLA_UPDATE_CANDIDATE" 2>/dev/null || true
  fi
  if [[ -n "$OLA_UPDATE_CHECKSUM_FILE" && -f "$OLA_UPDATE_CHECKSUM_FILE" ]]; then
    rm -f "$OLA_UPDATE_CHECKSUM_FILE" 2>/dev/null || true
  fi
}

update_exit_cleanup(){
  update_cleanup_files
  update_lock_release
}

update_download(){
  local url=$1 dest=$2 label=$3 max_bytes=$4
  if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 --proto-redir =https --max-filesize "$max_bytes" "$url" > "$dest"; then
    rm -f "$dest"
    die "Téléchargement impossible ou trop volumineux (limite $max_bytes octets) : $label ($url). Vérifie la connexion Internet puis réessaie."
  fi
  [[ -s "$dest" ]] || die "Téléchargement vide : $label ($url)."
}

update_expected_sha256(){
  local checksum_file=$1 expected="" listed_file="" url_file=""
  expected=$(awk 'NR == 1 { print tolower($1) }' "$checksum_file" 2>/dev/null || true)
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] \
    || die "Le fichier SHA-256 publié est invalide ; mise à jour refusée."
  listed_file=$(awk 'NR == 1 { print $2 }' "$checksum_file" 2>/dev/null || true)
  listed_file=${listed_file#\*}
  listed_file=${listed_file#./}
  if [[ -n "$listed_file" ]]; then
    url_file=${OLA_UPDATE_URL%%\?*}
    url_file=${url_file##*/}
    [[ "$listed_file" == "$url_file" ]] \
      || die "Le fichier SHA-256 publié concerne '$listed_file', pas '$url_file' ; mise à jour refusée."
  fi
  printf '%s' "$expected"
}

update_validate_candidate(){
  local candidate=$1
  [[ -s "$candidate" ]] || die "L'artefact téléchargé est vide ; mise à jour refusée."
  [[ "$(head -n 1 "$candidate" 2>/dev/null || true)" == "#!/usr/bin/env bash" ]] \
    || die "L'artefact téléchargé n'est pas un script Bash ola ; mise à jour refusée."
  grep -Fq "Ollama + Cloudflare Tunnel quick/named setup" "$candidate" \
    || die "L'artefact téléchargé ne ressemble pas au gestionnaire ola ; mise à jour refusée."
  grep -Fq "install_ola_command()" "$candidate" \
    || die "L'artefact téléchargé est incomplet ; mise à jour refusée."
  grep -Fq "update_ola_command" "$candidate" \
    || die "L'artefact téléchargé ne prend pas en charge 'ola update' ; mise à jour refusée."
  bash -n "$candidate" \
    || die "L'artefact téléchargé a une syntaxe Bash invalide ; mise à jour refusée."
}

update_repair_tui_if_needed(){
  local old_requirements_hash=${1:-} new_requirements_hash=${2:-} version=""
  [[ -x "$OLA_TUI_PYTHON" ]] || return 0
  version=$(tui_textual_version 2>/dev/null || true)
  if [[ "$old_requirements_hash" != "$new_requirements_hash" || "$version" != "$OLA_TUI_TEXTUAL_VERSION" ]]; then
    info "Les dépendances de la TUI ont changé — réparation de son environnement Python isolé…"
    if ! install_tui_environment; then
      warn "La TUI n'a pas pu être réparée automatiquement. Le reste de ola est à jour ; réessaie avec : sudo ola tui install"
    fi
  fi
}

update_rollback(){
  local message=$1 tmp=""
  warn "$message"
  if [[ "${update_had_script:-0}" -eq 1 && -f "$OLA_UPDATE_BACKUP_DIR/ollama-cloudflare-setup.sh.bak" ]]; then
    warn "Restauration de la version précédente de ola…"
    tmp=$(mktemp "$OLA_INSTALL_DIR/.ola-rollback.XXXXXX") || tmp=""
    if [[ -n "$tmp" ]] && install -m 0755 "$OLA_UPDATE_BACKUP_DIR/ollama-cloudflare-setup.sh.bak" "$tmp"; then
      mv -f "$tmp" "$OLA_SCRIPT" || { rm -f "$tmp"; warn "La restauration du script a échoué."; }
    else
      [[ -n "$tmp" ]] && rm -f "$tmp"
      warn "La restauration du script a échoué."
    fi
  elif [[ "${update_had_script:-0}" -eq 0 ]]; then
    rm -f "$OLA_SCRIPT" 2>/dev/null || true
    if [[ -L "$OLA_COMMAND" && "$(readlink -f "$OLA_COMMAND" 2>/dev/null || true)" == "$OLA_SCRIPT" ]]; then
      rm -f "$OLA_COMMAND" 2>/dev/null || true
    fi
  fi
  if [[ "${update_had_tui_file:-0}" -eq 1 && -f "$OLA_UPDATE_BACKUP_DIR/ola_tui.py.bak" ]]; then
    install -m 0755 "$OLA_UPDATE_BACKUP_DIR/ola_tui.py.bak" "$OLA_TUI_FILE" 2>/dev/null || true
  fi
  if [[ "${update_had_requirements:-0}" -eq 1 && -f "$OLA_UPDATE_BACKUP_DIR/tui-requirements.txt.bak" ]]; then
    install -m 0644 "$OLA_UPDATE_BACKUP_DIR/tui-requirements.txt.bak" "$OLA_TUI_REQUIREMENTS" 2>/dev/null || true
  fi
  if [[ "${update_was_configured:-0}" -eq 1 && -x "$OLA_SCRIPT" ]]; then
    warn "Redémarrage des services avec la version restaurée…"
    bash "$OLA_SCRIPT" start || warn "La version précédente a été restaurée, mais son redémarrage a échoué. Vérifie avec : ola doctor"
  fi
  die "Mise à jour échouée ; la version précédente a été restaurée quand c'était possible. Sauvegarde : $OLA_UPDATE_BACKUP_DIR"
}

apply_downloaded_update(){
  local candidate=${OLA_UPDATE_CANDIDATE:-} expected=${OLA_UPDATE_NEW_SHA256:-}
  local source="" actual="" installed_hash="" new_hash=""
  local old_requirements_hash="" new_requirements_hash=""
  local update_had_script=0 update_had_tui_file=0 update_had_requirements=0 update_was_configured=0

  [[ -n "$candidate" && -f "$candidate" ]] \
    || die "Mise à jour interne : l'artefact téléchargé est introuvable."
  source=$(script_source_path) \
    || die "Mise à jour interne : impossible de localiser l'artefact téléchargé."
  [[ "$source" == "$candidate" ]] \
    || die "Mise à jour interne : le script en cours n'est pas l'artefact téléchargé."
  actual=$(update_file_sha256 "$candidate" || true)
  [[ -n "$expected" && "$actual" == "$expected" ]] \
    || die "Mise à jour interne : le SHA-256 de l'artefact a changé avant installation."

  OLA_UPDATE_CANDIDATE="$candidate"
  trap update_exit_cleanup EXIT
  update_lock_acquire

  select_supervisor_paths
  [[ -f "$SUP_DIR/ollama.conf" ]] && update_was_configured=1
  installed_hash=$(update_file_sha256 "$OLA_SCRIPT" || true)
  old_requirements_hash=$(update_file_sha256 "$OLA_TUI_REQUIREMENTS" || true)
  [[ -f "$OLA_SCRIPT" ]] && update_had_script=1
  [[ -f "$OLA_TUI_FILE" ]] && update_had_tui_file=1
  [[ -f "$OLA_TUI_REQUIREMENTS" ]] && update_had_requirements=1

  install -d -m 0755 "$OLA_UPDATE_BACKUP_DIR" \
    || die "Impossible de créer le dossier de sauvegarde : $OLA_UPDATE_BACKUP_DIR"
  if [[ "$update_had_script" -eq 1 ]]; then
    cp -a "$OLA_SCRIPT" "$OLA_UPDATE_BACKUP_DIR/ollama-cloudflare-setup.sh.bak" \
      || die "Impossible de sauvegarder la version actuelle de ola."
  fi
  if [[ "$update_had_tui_file" -eq 1 ]]; then
    cp -a "$OLA_TUI_FILE" "$OLA_UPDATE_BACKUP_DIR/ola_tui.py.bak" || true
  fi
  if [[ "$update_had_requirements" -eq 1 ]]; then
    cp -a "$OLA_TUI_REQUIREMENTS" "$OLA_UPDATE_BACKUP_DIR/tui-requirements.txt.bak" || true
  fi

  info "Installation de la nouvelle version de ola…"
  install_ola_command
  new_hash=$(update_file_sha256 "$OLA_SCRIPT" || true)
  if [[ "$new_hash" != "$expected" ]]; then
    update_rollback "La copie installée ne correspond pas au SHA-256 vérifié."
  fi
  new_requirements_hash=$(update_file_sha256 "$OLA_TUI_REQUIREMENTS" || true)
  update_repair_tui_if_needed "$old_requirements_hash" "$new_requirements_hash"

  if [[ "$update_was_configured" -eq 1 ]]; then
    info "Redémarrage des services avec la nouvelle version…"
    if ! ( require_supervisor_running && ensure_watchdog && restart_services ); then
      update_rollback "Le redémarrage des services avec la nouvelle version a échoué."
    fi
    if ! wait_for_ollama_api 30; then
      update_rollback "L'API Ollama ne répond pas après la mise à jour."
    fi
  else
    warn "Aucun service Ollama configuré n'a été détecté : ola a été installé, mais aucun redémarrage n'a été tenté. Lance un setup pour configurer les services."
  fi

  ok "Mise à jour de ola installée : $(update_short_hash "$installed_hash") → $(update_short_hash "$new_hash")"
  echo "Version précédente conservée dans : $OLA_UPDATE_BACKUP_DIR"
  echo "Vérifications conseillées : ola doctor ; ola test ; ola tui status"
}

update_ola_command(){
  local installed_hash="" candidate_hash="" expected=""

  require_root
  if [[ "${OLA_UPDATE_APPLY:-0}" == "1" ]]; then
    apply_downloaded_update
    return 0
  fi

  case "$OLA_UPDATE_URL" in
    https://*) ;;
    *) die "OLA_UPDATE_URL doit utiliser HTTPS ; mise à jour refusée." ;;
  esac
  case "$OLA_UPDATE_SHA256_URL" in
    https://*) ;;
    *) die "OLA_UPDATE_SHA256_URL doit utiliser HTTPS ; mise à jour refusée." ;;
  esac

  require_commands curl sha256sum awk grep head install mktemp
  update_lock_acquire
  trap update_exit_cleanup EXIT

  install -d -m 0755 "$OLA_INSTALL_DIR" \
    || die "Impossible de créer $OLA_INSTALL_DIR pour la mise à jour."
  OLA_UPDATE_CANDIDATE=$(mktemp "$OLA_INSTALL_DIR/.ola-update.XXXXXX") \
    || die "Impossible de créer le fichier temporaire de mise à jour."
  OLA_UPDATE_CHECKSUM_FILE=$(mktemp "$OLA_INSTALL_DIR/.ola-update-sha256.XXXXXX") \
    || die "Impossible de créer le fichier temporaire SHA-256."
  chmod 0600 "$OLA_UPDATE_CANDIDATE" "$OLA_UPDATE_CHECKSUM_FILE" \
    || die "Impossible de protéger les fichiers temporaires de mise à jour."

  echo "--- Mise à jour de ola ---"
  info "Téléchargement de la dernière version publiée…"
  update_download "$OLA_UPDATE_URL" "$OLA_UPDATE_CANDIDATE" "artefact ola" "$OLA_UPDATE_MAX_ARTIFACT_BYTES"
  info "Téléchargement du SHA-256 publié…"
  update_download "$OLA_UPDATE_SHA256_URL" "$OLA_UPDATE_CHECKSUM_FILE" "SHA-256 ola" "$OLA_UPDATE_MAX_CHECKSUM_BYTES"
  expected=$(update_expected_sha256 "$OLA_UPDATE_CHECKSUM_FILE")
  candidate_hash=$(update_file_sha256 "$OLA_UPDATE_CANDIDATE" || true)
  [[ "$candidate_hash" == "$expected" ]] \
    || die "SHA-256 différent pour l'artefact téléchargé ; mise à jour refusée. Attendu $expected, reçu ${candidate_hash:-inconnu}."
  update_validate_candidate "$OLA_UPDATE_CANDIDATE"
  chmod 0755 "$OLA_UPDATE_CANDIDATE" \
    || die "Impossible de rendre l'artefact téléchargé exécutable."

  installed_hash=$(update_file_sha256 "$OLA_SCRIPT" || true)
  if [[ -n "$installed_hash" && "$installed_hash" == "$candidate_hash" ]]; then
    ok "ola est déjà à jour (SHA-256 $(update_short_hash "$candidate_hash"))."
    install_ola_command
    update_repair_tui_if_needed "$(update_file_sha256 "$OLA_TUI_REQUIREMENTS" || true)" "$(update_file_sha256 "$OLA_TUI_REQUIREMENTS" || true)"
    return 0
  fi

  info "Nouvelle version : $(update_short_hash "$installed_hash") → $(update_short_hash "$candidate_hash")"
  info "Passage de relais à la version téléchargée pour l'installation…"
  export OLA_UPDATE_APPLY=1
  export OLA_UPDATE_CANDIDATE="$OLA_UPDATE_CANDIDATE"
  export OLA_UPDATE_NEW_SHA256="$candidate_hash"
  exec bash "$OLA_UPDATE_CANDIDATE" update
  die "Impossible d'exécuter l'artefact téléchargé pour terminer la mise à jour."
}
