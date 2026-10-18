show_speed(){
  local mode flash kv mem_kb loaded installed saved_default model
  select_supervisor_paths
  mode=$(saved_speed_mode)
  echo "--- Ola speed (Pack Speed) ---"
  if [[ -f "$SPEED_FILE" && ! -r "$SPEED_FILE" ]]; then
    echo "Mode enregistré : non lisible sans root (fichier $SPEED_FILE)"
  else
    echo "Mode enregistré : $mode (fichier $SPEED_FILE)"
  fi
  echo "Configuration Supervisor effective ($SUP_DIR/ollama.conf) :"
  if [[ -r "$SUP_DIR/ollama.conf" ]]; then
    flash=$(ollama_config_value OLLAMA_FLASH_ATTENTION)
    kv=$(ollama_config_value OLLAMA_KV_CACHE_TYPE)
    echo "  OLLAMA_FLASH_ATTENTION : ${flash:-non défini (désactivé)}"
    echo "  OLLAMA_KV_CACHE_TYPE   : ${kv:-non défini (f16 par défaut)}"
    echo "  OLLAMA_CONTEXT_LENGTH  : $(ollama_config_value OLLAMA_CONTEXT_LENGTH)"
    echo "  OLLAMA_KEEP_ALIVE      : $(ollama_config_value OLLAMA_KEEP_ALIVE)"
    echo "  OLLAMA_MAX_LOADED_MODELS : $(ollama_config_value OLLAMA_MAX_LOADED_MODELS)"
    echo "  OLLAMA_NUM_PARALLEL    : $(ollama_config_value OLLAMA_NUM_PARALLEL)"
  else
    echo "  Non lisible par cet utilisateur (relance en root pour le détail)."
  fi
  echo "CPU : $(cpu_logical_cores) logique(s), environ $(cpu_physical_cores) physique(s) — $(cpu_speed_summary)"
  mem_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    echo "RAM disponible : environ $((mem_kb / 1024)) MB"
  fi
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && ollama_api_ready; then
    installed=$(installed_model_names 2>/dev/null || true)
    saved_default=$(saved_model_name)
    if [[ -n "$installed" ]]; then
      echo "Modèles présents pris en compte par l'optimisation globale :"
      while IFS= read -r model; do
        [[ -n "$model" ]] || continue
        if [[ "$(normalize_model_name "$model")" == "$(normalize_model_name "$saved_default")" ]]; then
          echo "  - $model [défaut]"
        else
          echo "  - $model"
        fi
      done <<< "$installed"
    else
      echo "Aucun modèle téléchargé présent pour le moment."
    fi
    loaded=$(loaded_model_names 2>/dev/null || true)
    if [[ -n "$loaded" ]]; then
      echo "Modèle(s) chargé(s) en RAM : $(printf '%s' "$loaded" | tr '\n' ' ')"
    else
      echo "Aucun modèle chargé en RAM pour le moment."
    fi
  else
    echo "API Ollama locale non joignable : liste des modèles présents et état RAM inconnus."
  fi
  cat <<'EOF'

Portée : ces réglages vivent dans le processus serveur Ollama. Ils s'appliquent donc à tous les modèles
présents servis par Ollama, pas seulement au modèle par défaut. "ola bench" sans nom de modèle les teste
tous, un par un ; "ola speed apply/reset" mesure et vérifie aussi chaque modèle présent, un par un.
Ce que "ola speed apply" change (avec mesure avant/après et retour arrière auto si Ollama ne répond plus) :
  OLLAMA_FLASH_ATTENTION=1 et OLLAMA_KV_CACHE_TYPE=q8_0 (cache KV ~2x plus léger que f16, gain RAM et vitesse possible).
Ce qu'il ne change jamais : OLLAMA_NUM_PARALLEL=1, OLLAMA_MAX_LOADED_MODELS=1 et le contexte,
car les augmenter coûterait de la RAM sans rendre une requête seule plus rapide.
Le keep-alive serveur (5m par défaut) n'est pas touché par Pack Speed ; il se règle à part, délibérément :
ola fluid keepalive <durée|reset> (voir ola fluid pour l'état complet et le compromis RAM).
Revenir en arrière : ola speed reset
Mesurer avant/après : ola bench (tous les modèles présents) ou ola bench <modèle> (un seul)
Fluidité ressentie (1er token, streaming local/public) : ola bench --stream, ola fluid warm, ola fluid preset
EOF
}

rollback_speed_config(){
  local backup=$1 prev_existed=$2 prev_value=$3
  cp -a "$backup" "$SUP_DIR/ollama.conf" 2>/dev/null || true
  chmod 600 "$SUP_DIR/ollama.conf" 2>/dev/null || true
  if [[ "$prev_existed" -eq 1 ]]; then
    printf '%s\n' "$prev_value" > "$SPEED_FILE" 2>/dev/null || true
    chmod 600 "$SPEED_FILE" 2>/dev/null || true
  else
    rm -f "$SPEED_FILE"
  fi
  supervisor_apply >/dev/null 2>&1 || true
  supervisor_ctl start ollama >/dev/null 2>&1 || true
  wait_for_supervisor_program ollama 30 >/dev/null 2>&1 || true
  wait_for_ollama_api 30 || true
}

verify_model_chat(){
  local model=$1 payload
  is_valid_model_name "$model" || return 1
  payload=$(jq -cn --arg model "$model" '{model:$model, messages:[{role:"user", content:"Reply only with OK."}], stream:false, options:{num_predict:16}}') || return 1
  curl -fsS --max-time 180 http://127.0.0.1:11434/api/chat \
    -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1
}

# One short speed measurement for a model. Prefers think:false, then falls
# back to the model's default behaviour for models that refuse think:false.
measure_model_once(){
  local model=$1 res
  if res=$(bench_run "$model" off); then
    printf '%s' "$res"
    return 0
  fi
  if res=$(bench_run "$model" default); then
    printf '%s' "$res"
    return 0
  fi
  return 1
}

apply_speed_mode(){
  local target=$1 ollama_bin current installed saved_default ordered backup prev_speed_existed=0 prev_speed_value=""
  local -a present_models=() before_labels=() before_ok=() after_labels=()
  local model res idx regression_models="" verified_after=0 already_failing=0 bench_status=0
  select_supervisor_paths
  [[ -f "$SUP_DIR/ollama.conf" ]] || die "Ollama Supervisor config not found: $SUP_DIR/ollama.conf. Run setup first: ola setup"
  ollama_bin=$(ollama_bin_path) || die "Ollama binary not found. Run setup first: ola setup"
  require_commands curl jq
  ensure_service_users
  current=$(saved_speed_mode)

  if ! supervisor_program_running ollama; then
    info "Ollama is not RUNNING; starting it before applying the speed mode..."
    supervisor_ctl start ollama 2>/dev/null || supervisor_ctl restart ollama \
      || die "Could not start Ollama. Check: ola logs"
    wait_for_supervisor_program ollama 30 || die "Ollama did not reach RUNNING. Check: ola logs"
  fi
  ollama_api_ready || die "Ollama API is not answering. Try: ola recover"

  installed=$(installed_model_names) || die "Could not read the installed model list from Ollama."
  saved_default=$(saved_model_name)
  ordered=$(ordered_present_model_names "$installed" "$saved_default")
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    if is_valid_model_name "$model"; then
      present_models+=("$model")
    else
      warn "Ignoring an installed model with an unexpected name: $model"
    fi
  done <<< "$ordered"

  if [[ "$current" == "$target" ]] && speed_config_matches "$target"; then
    ok "Speed mode is already set: $target (Supervisor config already matches, server-wide)."
    if [[ ${#present_models[@]} -eq 0 ]]; then
      show_speed
      return 0
    fi
    info "No config change or restart is needed; checking every present model in the current mode so newly added models are included..."
    bench_status=0
    run_bench "" || bench_status=$?
    return "$bench_status"
  fi

  if [[ ${#present_models[@]} -gt 0 ]]; then
    info "Portée globale : ${#present_models[@]} modèle(s) présent(s) pris en compte, un par un : $(printf '%s' "$installed" | tr '\n' ' ')"
    info "Measuring current speed for every present model before the change (short test, one model at a time)..."
    for idx in "${!present_models[@]}"; do
      model="${present_models[$idx]}"
      stop_loaded_models_except_soft "$model"
      if res=$(measure_model_once "$model"); then
        before_labels[idx]=$(printf '%s' "$res" | cut -f4)
        before_ok[idx]=1
        info "Before [$model]: generation ${before_labels[$idx]} tok/s"
      elif verify_model_chat "$model"; then
        before_labels[idx]="répond, vitesse non mesurée"
        before_ok[idx]=1
        warn "Before [$model]: the model answers, but its short speed measurement failed."
      else
        before_labels[idx]="échec avant changement"
        before_ok[idx]=0
        warn "Before [$model]: this model did not answer before the change; it will be rechecked after, without forcing a rollback by itself."
      fi
    done
  else
    warn "No downloaded model is present; applying the server-wide speed mode with an API-only verification."
  fi

  backup=$(mktemp) || die "Could not create a temporary backup of the Ollama Supervisor config."
  cp -a "$SUP_DIR/ollama.conf" "$backup" || { rm -f "$backup"; die "Could not back up $SUP_DIR/ollama.conf."; }
  if [[ -f "$SPEED_FILE" ]]; then
    prev_speed_existed=1
    prev_speed_value=$(head -n 1 "$SPEED_FILE" 2>/dev/null || true)
  fi

  info "Applying server-wide speed mode: $target (applies to every model served by Ollama, not only the default)"
  save_speed_mode "$target"
  write_ollama_supervisor_config "$ollama_bin" "$target"
  supervisor_apply
  supervisor_ctl start ollama >/dev/null 2>&1 || true
  if ! wait_for_supervisor_program ollama 30 || ! wait_for_ollama_api 30; then
    warn "Ollama did not come back after applying speed mode $target; restoring the previous configuration..."
    rollback_speed_config "$backup" "$prev_speed_existed" "$prev_speed_value"
    rm -f "$backup"
    die "Speed mode $target could not be applied; the previous Ollama configuration was restored. Check: ola logs"
  fi

  if [[ ${#present_models[@]} -gt 0 ]]; then
    info "Verifying and measuring every present model after the change (same short test, one model at a time)..."
    for idx in "${!present_models[@]}"; do
      model="${present_models[$idx]}"
      stop_loaded_models_except_soft "$model"
      if res=$(measure_model_once "$model"); then
        after_labels[idx]=$(printf '%s' "$res" | cut -f4)
        verified_after=$((verified_after + 1))
      elif verify_model_chat "$model"; then
        after_labels[idx]="répond, vitesse non mesurée"
        verified_after=$((verified_after + 1))
        warn "After [$model]: the model answers, but its short speed measurement failed."
      else
        after_labels[idx]="échec après changement"
        if [[ "${before_ok[$idx]:-0}" -eq 1 ]]; then
          regression_models="${regression_models} ${model}"
        else
          already_failing=$((already_failing + 1))
        fi
      fi
      echo "[$model] Avant : ${before_labels[$idx]:-non mesuré} · Après : ${after_labels[$idx]:-non mesuré}"
    done

    if [[ -n "$regression_models" ]]; then
      warn "At least one model that worked before no longer answers after speed mode $target:${regression_models}; restoring the previous configuration..."
      rollback_speed_config "$backup" "$prev_speed_existed" "$prev_speed_value"
      rm -f "$backup"
      die "Speed mode $target failed verification for:${regression_models}. The previous Ollama configuration was restored. Check: ola logs"
    fi
    if [[ "$already_failing" -gt 0 ]]; then
      warn "$already_failing present model(s) were already failing before the change and still fail; they did not trigger a rollback."
    fi
    ok "Verification passed for $verified_after/${#present_models[@]} present model(s) with speed mode: $target"
  else
    ok "Ollama API verification passed with speed mode: $target (no downloaded model to chat-test)"
  fi

  rm -f "$backup"
  ok "Speed mode is now: $target, for every model served by Ollama. Full per-model comparison anytime with: ola bench"
  if [[ "$target" == "speed" ]]; then
    echo "Actif pour tout le serveur Ollama : OLLAMA_FLASH_ATTENTION=1, OLLAMA_KV_CACHE_TYPE=q8_0. Inchangés : contexte $OLLAMA_CONTEXT_LENGTH, 1 modèle chargé, 1 requête parallèle, keep-alive 5m."
  else
    echo "Configuration équilibrée restaurée pour tout le serveur Ollama (pas de Flash Attention, cache KV par défaut). Inchangés : contexte, parallélisme et keep-alive."
  fi
}
