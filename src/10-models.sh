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
  # A runner can take a few seconds to release a model after a request (and
  # can still be busy finishing one). Do not give up after a single unload
  # request: re-send the official keep_alive:0 request while polling /api/ps
  # for about 30 seconds in total.
  for _ in 1 2 3; do
    if curl -fsS --max-time 30 http://127.0.0.1:11434/api/generate \
      -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1; then
      for i in $(seq 1 10); do
        names=$(loaded_model_names) || return 1
        model_names_contain "$names" "$model" || return 0
        sleep 1
      done
    else
      names=$(loaded_model_names) || return 1
      model_names_contain "$names" "$model" || return 0
      sleep 2
    fi
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

# Softer variant for benchmark / speed-apply sequences: if a model stays in
# RAM after the retried unload (for example because it is still finishing a
# request), warn and continue the sequence instead of aborting everything.
# The next request still asks Ollama for the target model, and the server is
# configured with OLLAMA_MAX_LOADED_MODELS=1. Strict callers (model switch,
# deletion, setup) keep using stop_loaded_models_except above.
stop_loaded_models_except_soft(){
  local target=$1 target_norm loaded_names loaded
  target_norm=$(normalize_model_name "$target")
  loaded_names=$(loaded_model_names) \
    || die "Could not read the list of models currently loaded in RAM from Ollama. Refusing to continue blindly."
  while IFS= read -r loaded; do
    [[ -n "$loaded" ]] || continue
    if [[ "$(normalize_model_name "$loaded")" != "$target_norm" ]]; then
      info "Unloading current model from RAM first: $loaded"
      if unload_model "$loaded"; then
        ok "Model unloaded from RAM: $loaded"
      else
        warn "Could not unload $loaded from RAM after repeated attempts (it may still be busy). Continuing the sequence: the next request will ask Ollama for $target, and Ollama is limited to one loaded model."
      fi
    fi
  done <<< "$loaded_names"
  return 0
}

pull_model_with_retry(){
  local model=$1 ollama_bin=$2 models_kb pull_attempt models_dir
  models_dir=$(saved_ollama_models_dir)
  [[ -n "$models_dir" ]] || models_dir="$OLLAMA_HOME"
  models_kb=$(free_kb "$models_dir")
  if [[ "$models_kb" -gt 0 && "$models_kb" -lt 2000000 ]]; then
    warn "Less than about 2 GB free on $models_dir. A larger model may fail while pulling; free disk space if needed."
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



format_model_size(){
  local bytes=${1:-0}
  if [[ ! "$bytes" =~ ^[0-9]+$ ]] || [[ "$bytes" -eq 0 ]]; then
    printf '%s' "taille inconnue"
  elif [[ "$bytes" -ge 1073741824 ]]; then
    awk -v b="$bytes" 'BEGIN { printf "%.1f GB", b / 1073741824 }'
  elif [[ "$bytes" -ge 1048576 ]]; then
    awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1048576 }'
  elif [[ "$bytes" -ge 1024 ]]; then
    awk -v b="$bytes" 'BEGIN { printf "%.1f KB", b / 1024 }'
  else
    printf '%s B' "$bytes"
  fi
}

read_model_action(){
  local -n _action_ref=$1
  local raw=""
  _action_ref=""
  # Read a whole line (key + Enter), not a single raw character: with a PTY,
  # Bash single-character reads can lose already-typed input after external
  # commands run. A line-based read is the reliable interactive behaviour.
  if ! IFS= read -r -p "Action (u utiliser, d supprimer, l libérer RAM, a ajouter+utiliser, r rafraîchir, q quitter, puis Entrée) : " raw; then
    return 1
  fi
  _action_ref=${raw:0:1}
}

read_manager_value(){
  local -n _value_ref=$1
  local prompt=$2 default=${3-}
  local value
  _value_ref=""
  if ! IFS= read -r -p "$prompt" value; then
    return 1
  fi
  _value_ref=${value:-$default}
}

selected_model_from_prompt(){
  local -n _selected_ref=$1
  local idx=""
  _selected_ref=""
  if ! read_manager_value idx "Numéro du modèle : " ""; then
    return 1
  fi
  [[ "$idx" =~ ^[0-9]+$ ]] || return 1
  [[ "$idx" -ge 1 && "$idx" -le ${#MODEL_MANAGER_NAMES[@]} ]] || return 1
  _selected_ref=${MODEL_MANAGER_NAMES[$((idx - 1))]}
}

model_manager(){
  local tags_json loaded_names current_default rows name size markers action selected prereqs_done=0 i
  require_commands curl jq
  while true; do
    if ! tags_json=$(curl -fsS --max-time 10 http://127.0.0.1:11434/api/tags 2>/dev/null); then
      die "Ollama API is not answering, so models cannot be managed. Try: ola recover"
    fi
    loaded_names=$(loaded_model_names 2>/dev/null || true)
    current_default=$(saved_model_name)
    MODEL_MANAGER_NAMES=()
    local model_sizes=()
    rows=$(printf '%s' "$tags_json" | jq -r '.models[]? | [.name, ((.size // 0) | tostring)] | @tsv' 2>/dev/null || true)
    while IFS=$'\t' read -r name size; do
      [[ -n "$name" ]] || continue
      MODEL_MANAGER_NAMES+=("$name")
      model_sizes+=("${size:-0}")
    done <<< "$rows"

    echo
    echo "================ Modèles Ollama ================"
    if [[ ${#MODEL_MANAGER_NAMES[@]} -eq 0 ]]; then
      echo "Aucun modèle téléchargé pour le moment."
    else
      for i in "${!MODEL_MANAGER_NAMES[@]}"; do
        markers=""
        if [[ "$(normalize_model_name "${MODEL_MANAGER_NAMES[$i]}")" == "$(normalize_model_name "$current_default")" ]]; then
          markers="$markers [défaut]"
        fi
        if model_names_contain "$loaded_names" "${MODEL_MANAGER_NAMES[$i]}"; then
          markers="$markers [RAM]"
        fi
        printf '%2d) %-32s %14s%s\n' "$((i + 1))" "${MODEL_MANAGER_NAMES[$i]}" "$(format_model_size "${model_sizes[$i]}")" "$markers"
      done
    fi
    echo "--------------------------------------------------"
    echo "u = utiliser    d = supprimer    l = libérer la RAM"
    echo "a = ajouter + utiliser un autre modèle"
    echo "r = rafraîchir  q = quitter"
    if [[ $EUID -ne 0 ]]; then
      echo "Mode lecture seule : lance ola models en root pour utiliser/supprimer."
    fi

    if ! read_model_action action; then
      echo
      break
    fi
    action=${action,,}

    case "$action" in
      q|"")
        [[ "$action" == "q" ]] && break
        ;;
      r)
        ;;
      a)
        if [[ $EUID -ne 0 ]]; then
          warn "Root requis pour ajouter/utiliser un modèle. Relance : sudo ola models"
          continue
        fi
        if [[ "$prereqs_done" -eq 0 ]]; then
          install_ola_command < /dev/null
          require_supervisor_running < /dev/null
          ensure_watchdog < /dev/null
          prereqs_done=1
        fi
        if ! read_manager_value selected "Nom du modèle à télécharger et utiliser : " ""; then
          warn "Ajout annulé."
          continue
        fi
        [[ -n "$selected" ]] || { warn "Nom de modèle vide; ajout annulé."; continue; }
        switch_model "$selected" < /dev/null
        ;;
      u|d|l)
        if [[ ${#MODEL_MANAGER_NAMES[@]} -eq 0 ]]; then
          warn "Aucun modèle à gérer. Utilise 'a' pour en ajouter un."
          continue
        fi
        if ! selected_model_from_prompt selected; then
          warn "Numéro invalide; action annulée."
          continue
        fi
        if [[ $EUID -ne 0 ]]; then
          warn "Root requis pour cette action. Relance : sudo ola models"
          continue
        fi
        if [[ "$prereqs_done" -eq 0 ]]; then
          install_ola_command < /dev/null
          require_supervisor_running < /dev/null
          ensure_watchdog < /dev/null
          prereqs_done=1
        fi
        case "$action" in
          u)
            switch_model "$selected" < /dev/null
            ;;
          l)
            unload_models_command "$selected" < /dev/null
            ;;
          d)
            if [[ "$(normalize_model_name "$current_default")" == "$(normalize_model_name "$selected")" ]]; then
              delete_model_command "$selected" 1 < /dev/null
            else
              delete_model_command "$selected" 0 < /dev/null
            fi
            ;;
        esac
        ;;
      *)
        warn "Action inconnue : $action"
        ;;
    esac
  done
}

show_installed_models(){
  local names
  require_commands curl jq
  if ! names=$(installed_model_names); then
    die "Ollama API is not answering, so installed models cannot be listed. Try: ola recover"
  fi
  if [[ -z "$names" ]]; then
    echo "No model is currently downloaded on disk."
  else
    echo "Models currently downloaded on disk:"
    printf '%s\n' "$names"
  fi
}

delete_model_command(){
  local target=$1 force=${2:-0} ollama_bin installed_names loaded_names current_default payload remaining new_default i
  is_valid_model_name "$target" || die "Invalid model name: $target (example: qwen3:1.7b)"
  require_commands curl jq
  ollama_bin=$(ollama_bin_path) || die "Ollama binary not found. Run setup first: ola setup"

  if ! supervisor_program_running ollama; then
    info "Ollama is not RUNNING; starting it before deleting the model..."
    supervisor_ctl start ollama 2>/dev/null || supervisor_ctl restart ollama \
      || die "Could not start Ollama. Check: ola logs"
    wait_for_supervisor_program ollama 30 || die "Ollama did not reach RUNNING. Check: ola logs"
  fi
  ollama_api_ready || die "Ollama API is not answering. Try: ola recover"

  installed_names=$(installed_model_names) \
    || die "Could not read the installed model list from Ollama."
  if ! model_names_contain "$installed_names" "$target"; then
    ok "Model is not downloaded on disk: $target"
    return 0
  fi

  current_default=$(saved_model_name)
  if [[ "$(normalize_model_name "$current_default")" == "$(normalize_model_name "$target")" && "$force" -ne 1 ]]; then
    die "Refusing to delete the current default model '$target'. Switch first with: ola use <another-model> — or force it with: ola delete $target --force"
  fi

  loaded_names=$(loaded_model_names) || die "Could not list models loaded in RAM."
  if model_names_contain "$loaded_names" "$target"; then
    info "Model is loaded in RAM; unloading it before disk deletion: $target"
    unload_model "$target" \
      || die "Could not unload model $target from RAM. It may be busy; try again in a moment."
    ok "Model unloaded from RAM: $target"
  fi

  warn "Permanently deleting model from disk: $target"
  payload=$(jq -cn --arg model "$target" '{model:$model}') || die "Could not build the model deletion request."
  if ! curl -fsS --max-time 60 -X DELETE http://127.0.0.1:11434/api/delete \
    -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1; then
    warn "The Ollama delete API did not accept the request; trying the Ollama CLI fallback..."
    "$ollama_bin" rm "$target" \
      || die "Could not delete model: $target. Check the exact name with: ola models"
  fi

  for i in $(seq 1 30); do
    installed_names=$(installed_model_names) || die "Could not verify model deletion."
    model_names_contain "$installed_names" "$target" || break
    if [[ "$i" -eq 30 ]]; then
      die "Model $target still appears in the installed list after deletion. Check: ola logs"
    fi
    sleep 1
  done

  if [[ "$(normalize_model_name "$current_default")" == "$(normalize_model_name "$target")" ]]; then
    remaining=$(installed_model_names) || die "Model deleted, but the remaining model list could not be read."
    if [[ -n "$remaining" ]]; then
      new_default=$(printf '%s\n' "$remaining" | head -n 1)
      printf '%s\n' "$new_default" > "$MODEL_FILE" \
        || die "Model deleted, but the new default model could not be saved."
      chmod 600 "$MODEL_FILE" || die "Could not set permissions on $MODEL_FILE."
      warn "Default model was deleted; the new default is: $new_default"
    else
      rm -f "$MODEL_FILE"
      warn "Default model was deleted and no downloaded model remains. Install one with: ola use <model>"
    fi
  fi
  ok "Model permanently deleted from disk: $target"
}

switch_model(){
  local target=$1 ollama_bin installed_names loaded_names payload response content mem_kb
  is_valid_model_name "$target" || die "Invalid model name: $target (example: qwen3:1.7b)"
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
