# --- Pack Fluidité ---------------------------------------------------------
# Total generation speed (tok/s) is not what a user feels first. What is
# felt is: how long until the first visible token (time to first token,
# TTFT), and whether the streamed tokens then arrive regularly or in
# bursts. Ollama streams newline-delimited JSON chunks by default and puts
# the usage metrics in the final chunk. The helpers below measure TTFT and
# chunk gaps against the local API and, when a public URL is saved,
# through the tunnel too: Cloudflare documents that proxied responses are
# buffered unless the origin answers with Content-Type: text/event-stream,
# while Ollama streams NDJSON — so the public path is measured, not
# assumed to stream smoothly.

# Prints one streaming measurement as a TSV line: total_ms (wall clock),
# load_ms, time-to-first-visible-token ms, uncached-prompt tok/s,
# generation tok/s, generated tokens, prompt tokens, cached prompt tokens
# (-1 when unreported), largest gap ms between visible chunks, visible
# chunk count, response snippet. The request uses the fluid preset (fixed
# num_ctx/num_thread, 48 tokens max) and leaves the model warm for
# FLUID_WARM_KEEP_ALIVE so the next real request starts hot.
stream_bench_run(){
  local model=$1 base=$2 think_mode=$3 payload tmp_dir start_ns end_ns line content done_flag
  local -a pipe_status=()
  local times_file snippet_file final_file metrics _total_ns load_ns p_count p_ns e_count e_ns p_cached
  local first_ns gap_stats max_gap_ms chunk_count snippet
  tmp_dir=$(mktemp -d) || return 1
  times_file="$tmp_dir/times"; snippet_file="$tmp_dir/snippet"; final_file="$tmp_dir/final"
  : > "$times_file"; : > "$snippet_file"
  if [[ "$think_mode" == "off" ]]; then
    payload=$(jq -cn --arg model "$model" --argjson nctx "$OLLAMA_CONTEXT_LENGTH" --argjson threads "$(cpu_physical_cores)" --arg warm "$FLUID_WARM_KEEP_ALIVE" \
      '{model:$model, messages:[{role:"user", content:"Réponds en une phrase courte : pourquoi le ciel est bleu ?"}], stream:true, think:false, keep_alive:$warm, options:{num_ctx:$nctx, num_predict:48, temperature:0, num_thread:$threads}}') || { rm -rf "$tmp_dir"; return 1; }
  else
    payload=$(jq -cn --arg model "$model" --argjson nctx "$OLLAMA_CONTEXT_LENGTH" --argjson threads "$(cpu_physical_cores)" --arg warm "$FLUID_WARM_KEEP_ALIVE" \
      '{model:$model, messages:[{role:"user", content:"Réponds en une phrase courte : pourquoi le ciel est bleu ?"}], stream:true, keep_alive:$warm, options:{num_ctx:$nctx, num_predict:48, temperature:0, num_thread:$threads}}') || { rm -rf "$tmp_dir"; return 1; }
  fi
  start_ns=$(date +%s%N)
  curl -fsS -N --max-time 300 "${base}/api/chat" \
    -H 'Content-Type: application/json' -d "$payload" 2>/dev/null \
    | while IFS= read -r line; do
        content=$(printf '%s' "$line" | jq -r '.message.content // .response // ""' 2>/dev/null || true)
        if [[ -n "$content" ]]; then
          date +%s%N >> "$times_file"
          printf '%s' "$content" >> "$snippet_file"
        fi
        done_flag=$(printf '%s' "$line" | jq -r '.done // false' 2>/dev/null || true)
        if [[ "$done_flag" == "true" ]]; then
          printf '%s' "$line" > "$final_file"
        fi
      done
  pipe_status=("${PIPESTATUS[@]}")
  end_ns=$(date +%s%N)
  if [[ "${pipe_status[0]:-1}" -ne 0 || ! -s "$final_file" ]]; then
    rm -rf "$tmp_dir"
    return 1
  fi
  metrics=$(jq -r '[ (.total_duration // 0), (.load_duration // 0), (.prompt_eval_count // 0), (.prompt_eval_duration // 0), (.eval_count // 0), (.eval_duration // 0), (.prompt_eval_cached_count // -1) ] | @tsv' "$final_file" 2>/dev/null) || { rm -rf "$tmp_dir"; return 1; }
  IFS=$'\t' read -r _total_ns load_ns p_count p_ns e_count e_ns p_cached <<< "$metrics"
  first_ns=$(head -n 1 "$times_file" 2>/dev/null || true)
  gap_stats=$(awk 'NR == 1 { prev = $1 } NR > 1 { gap = $1 - prev; if (gap > max) max = gap; prev = $1 } END { printf "%d %d", max / 1000000, NR }' "$times_file")
  max_gap_ms=${gap_stats%% *}; chunk_count=${gap_stats##* }
  snippet=$(tr '\n\t' '  ' < "$snippet_file" | tr -d '\134' | cut -c1-90 || true)
  awk -v start="$start_ns" -v end="$end_ns" -v first="${first_ns:-0}" -v load="$load_ns" -v pc="$p_count" -v pd="$p_ns" -v ec="$e_count" -v ed="$e_ns" -v cached="$p_cached" -v gap="${max_gap_ms:-0}" -v chunks="${chunk_count:-0}" -v c="$snippet" \
    'BEGIN { uncached = pc; if (cached >= 0) { uncached = pc - cached; if (uncached < 0) uncached = 0 } ttft = (first > 0 ? (first - start) / 1000000 : (end - start) / 1000000); printf "%d\t%d\t%d\t%.1f\t%.1f\t%d\t%d\t%d\t%d\t%d\t%s", (end - start) / 1000000, load / 1000000, ttft, (pd > 0 ? uncached / (pd / 1000000000) : 0), (ed > 0 ? ec / (ed / 1000000000) : 0), ec, pc, cached, gap, chunks, c }'
  rm -rf "$tmp_dir"
}

# Populated by stream_bench_one_model.
LAST_STREAM_RES=""
LAST_STREAM_MODE=""

# Tries think:false first (fastest visible answer), then the model's
# default behaviour for models that refuse think:false.
stream_bench_one_model(){
  local model=$1 base=$2 res
  LAST_STREAM_RES=""; LAST_STREAM_MODE=""
  if res=$(stream_bench_run "$model" "$base" off); then
    LAST_STREAM_MODE="think:false"
  elif res=$(stream_bench_run "$model" "$base" default); then
    LAST_STREAM_MODE="thinking par défaut"
  else
    return 1
  fi
  LAST_STREAM_RES="$res"
  return 0
}

fmt_ms_s(){
  awk -v ms="${1:-0}" 'BEGIN { if (ms !~ /^[0-9]+$/) ms = 0; printf "%.1f", ms / 1000 }'
}

stream_print_line(){
  local label=$1 res=$2 total_ms load_ms ttft_ms p_tps e_tps _e_count _p_count _p_cached max_gap_ms chunk_count content
  IFS=$'\t' read -r total_ms load_ms ttft_ms p_tps e_tps _e_count _p_count _p_cached max_gap_ms chunk_count content <<< "$res"
  printf '%s : 1er token visible %s s · total %s s · chargement %s s · génération %s tok/s · prompt non caché %s tok/s · plus grand trou %s s · %s morceaux visibles\n' \
    "$label" "$(fmt_ms_s "${ttft_ms:-0}")" "$(fmt_ms_s "${total_ms:-0}")" "$(fmt_ms_s "${load_ms:-0}")" "${e_tps:-0}" "${p_tps:-0}" "$(fmt_ms_s "${max_gap_ms:-0}")" "${chunk_count:-0}"
  if [[ -n "${content:-}" ]]; then
    printf '   Réponse : %s\n' "$content"
  fi
}

run_stream_bench(){
  local requested=${1:-} installed loaded saved_default ordered public_base=""
  local -a present_models=() models_to_bench=() summary_lines=()
  local model idx global=0 successes=0 failures=0 public_failures=0
  local local_ttft local_load public_ttft public_gap conclusion
  require_commands curl jq
  ollama_api_ready || die "Ollama API is not answering, so the streaming benchmark cannot run. Try: ola recover"
  installed=$(installed_model_names) || die "Could not read the installed model list from Ollama."
  [[ -n "$installed" ]] || die "No model is currently downloaded on disk. Install one first with: ola use <model>"
  saved_default=$(saved_model_name)
  ordered=$(ordered_present_model_names "$installed" "$saved_default")
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    present_models+=("$model")
  done <<< "$ordered"

  if [[ -n "$requested" && "$requested" != "all" && "$requested" != "--all" ]]; then
    is_valid_model_name "$requested" || die "Invalid model name: $requested (example: qwen3:1.7b)"
    model_names_contain "$installed" "$requested" \
      || die "Model is not downloaded on disk: $requested. Install and load it first with: ola use $requested"
    models_to_bench=("$requested")
  else
    global=1
    models_to_bench=("${present_models[@]}")
  fi

  if [[ -r "$URL_FILE" ]]; then
    public_base=$(head -n 1 "$URL_FILE" 2>/dev/null || true)
  fi
  if [[ -n "$public_base" ]]; then
    if curl -fsS --max-time 10 "${public_base}/api/version" >/dev/null 2>&1; then
      info "URL publique enregistrée joignable : le streaming sera aussi mesuré à travers le tunnel ($public_base)."
    else
      warn "URL publique enregistrée non joignable depuis ce sandbox ($public_base) : mesure publique ignorée. Le DNS local du sandbox peut échouer alors que le tunnel fonctionne depuis l'extérieur ; vérifie aussi depuis ton navigateur/client."
      public_base=""
    fi
  else
    info "Aucune URL publique enregistrée lisible : mesure locale uniquement."
  fi

  echo "--- Ola bench streaming (fluidité) ---"
  if [[ "$global" -eq 1 ]]; then
    info "Portée globale : ${#models_to_bench[@]} modèle(s) présent(s) sur le disque, testés un par un, modèle par défaut en dernier."
  else
    info "Portée ciblée : un seul modèle."
  fi
  echo "Question courte identique, 48 tokens max, num_ctx $OLLAMA_CONTEXT_LENGTH, température 0, num_thread $(cpu_physical_cores), keep_alive $FLUID_WARM_KEEP_ALIVE (le modèle testé reste chaud ensuite)."
  echo "Le TTFT mesure le délai avant le premier morceau de réponse VISIBLE (le contenu 'thinking' caché ne compte pas)."

  for idx in "${!models_to_bench[@]}"; do
    model="${models_to_bench[$idx]}"
    echo
    echo "=== Modèle $((idx + 1))/${#models_to_bench[@]} : $model ==="
    stop_loaded_models_except_soft "$model"
    loaded=$(loaded_model_names 2>/dev/null || true)
    if model_names_contain "$loaded" "$model"; then
      info "Le modèle est déjà chargé en RAM."
    else
      info "Le modèle n'est pas encore chargé : le premier run inclura son temps de chargement."
    fi

    local_ttft=""; local_load=""; conclusion=""
    if stream_bench_one_model "$model" "http://127.0.0.1:11434"; then
      successes=$((successes + 1))
      stream_print_line "Local  ($LAST_STREAM_MODE)" "$LAST_STREAM_RES"
      local_ttft=$(printf '%s' "$LAST_STREAM_RES" | cut -f3)
      local_load=$(printf '%s' "$LAST_STREAM_RES" | cut -f2)
    else
      failures=$((failures + 1))
      err "Le streaming local a échoué pour le modèle : $model"
      summary_lines+=("$model | ÉCHEC du streaming local")
      continue
    fi

    if [[ -n "$public_base" ]]; then
      if stream_bench_one_model "$model" "$public_base"; then
        stream_print_line "Public ($LAST_STREAM_MODE)" "$LAST_STREAM_RES"
        public_ttft=$(printf '%s' "$LAST_STREAM_RES" | cut -f3)
        public_gap=$(printf '%s' "$LAST_STREAM_RES" | cut -f9)
        if [[ "$public_ttft" =~ ^[0-9]+$ && "$local_ttft" =~ ^[0-9]+$ ]] \
          && awk -v p="$public_ttft" -v l="$local_ttft" 'BEGIN { exit !(p > l * 1.5 && (p - l) > 500) }'; then
          conclusion="chemin public beaucoup plus lent à démarrer que le local : buffering du tunnel ou du client possible (mesuré, pas supposé)"
        elif [[ "$public_gap" =~ ^[0-9]+$ && "$public_gap" -gt 1000 ]]; then
          conclusion="flux public irrégulier sur ce test (trous > 1 s entre morceaux visibles)"
        else
          conclusion="démarrage local/public cohérents sur ce test"
        fi
        summary_lines+=("$model | TTFT local $(fmt_ms_s "$local_ttft") s | TTFT public $(fmt_ms_s "$public_ttft") s | $conclusion")
      else
        public_failures=$((public_failures + 1))
        warn "Le streaming public a échoué pour $model (le local fonctionne) : tunnel/client public à vérifier, voir ola doctor."
        summary_lines+=("$model | TTFT local $(fmt_ms_s "$local_ttft") s | streaming public EN ÉCHEC | vérifier le tunnel et le client public")
      fi
    else
      if [[ "$local_load" =~ ^[0-9]+$ && "$local_load" -ge 2000 ]]; then
        conclusion="premier token dominé par le chargement du modèle : garde-le chaud (ola fluid warm)"
      else
        conclusion="fluide sur ce test local"
      fi
      summary_lines+=("$model | TTFT local $(fmt_ms_s "$local_ttft") s | $conclusion")
    fi
  done

  if [[ "$global" -eq 1 || -n "$public_base" ]]; then
    echo
    echo "--- Synthèse fluidité ---"
    printf '%s\n' "${summary_lines[@]}"
  fi
  if [[ "$successes" -eq 0 ]]; then
    die "Streaming benchmark failed for every tested model. Check: ola logs"
  fi
  if [[ "$failures" -gt 0 ]]; then
    warn "Benchmark streaming terminé avec $failures échec(s) local/locaux et $successes succès."
  fi
  if [[ "$public_failures" -gt 0 ]]; then
    warn "$public_failures mesure(s) publique(s) en échec : cela vise le chemin tunnel/client, pas le modèle."
  fi
  cat <<EOF

Comment rendre les réponses plus fluides au quotidien :
  1. Garde UN seul modèle chaud pendant une session : ola fluid warm [modèle] (keep-alive $FLUID_WARM_KEEP_ALIVE), et libère la RAM ensuite avec ola unload.
  2. Envoie toujours le même preset stable à ce modèle (ola fluid preset [modèle]) : stream:true, think:false si le modèle l'accepte, même num_ctx à chaque requête — changer num_ctx ou certains réglages du runner entre deux requêtes peut forcer un rechargement du modèle.
  3. Garde un préfixe de prompt stable (même system prompt, historique dans le même ordre) : Ollama réutilise le cache du prompt pour la partie inchangée ; les compteurs "prompt non caché" ci-dessus le montrent.
  4. Limite num_predict au besoin réel et évite de changer de modèle au milieu d'une session.
  5. Si le TTFT public est très supérieur au TTFT local, le souci est le chemin public (tunnel/client), pas le modèle : compare toujours les deux lignes avant de changer de réglage serveur.
EOF
  [[ "$failures" -eq 0 ]]
}

fluid_keep_alive_for_requests(){
  if [[ "$(saved_keep_alive)" != "5m" ]]; then
    printf '%s' "$(saved_keep_alive)"
  else
    printf '%s' "$FLUID_WARM_KEEP_ALIVE"
  fi
}

show_fluid_status(){
  local keepalive_cfg mem_kb swap_kb ps_json ps_lines installed saved_default loaded_count public_url
  local m_name m_size m_expires m_ctx
  select_supervisor_paths
  echo "--- Ola fluidité ---"
  echo "Mode Pack Speed : $(saved_speed_mode) (détails : ola speed)"
  if [[ -f "$KEEPALIVE_FILE" && ! -r "$KEEPALIVE_FILE" ]]; then
    echo "Keep-alive serveur enregistré : non lisible sans root (fichier $KEEPALIVE_FILE)"
  else
    echo "Keep-alive serveur enregistré : $(saved_keep_alive) (fichier $KEEPALIVE_FILE)"
  fi
  if [[ -r "$SUP_DIR/ollama.conf" ]]; then
    keepalive_cfg=$(ollama_config_value OLLAMA_KEEP_ALIVE)
    echo "Keep-alive effectif (Supervisor) : ${keepalive_cfg:-inconnu}"
  else
    echo "Keep-alive effectif : non lisible par cet utilisateur (relance en root pour le détail)."
  fi
  echo "Keep-alive utilisé par 'ola fluid warm' et le bench streaming : $(fluid_keep_alive_for_requests) après chaque requête."
  mem_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    echo "RAM disponible : environ $((mem_kb / 1024)) MB"
  fi
  swap_kb=$(awk '/^SwapFree:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
  if [[ "$swap_kb" =~ ^[0-9]+$ ]]; then
    echo "Swap libre : environ $((swap_kb / 1024)) MB (si le swap se remplit pendant une réponse, le sandbox échange : réponses par à-coups)"
  fi
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && ollama_api_ready; then
    saved_default=$(saved_model_name)
    installed=$(installed_model_names 2>/dev/null || true)
    if [[ -n "$installed" ]]; then
      echo "Modèles présents sur le disque : $(printf '%s' "$installed" | tr '\n' ' ')(défaut : $saved_default)"
    fi
    ps_json=$(curl -fsS --max-time 10 http://127.0.0.1:11434/api/ps 2>/dev/null || true)
    ps_lines=$(printf '%s' "$ps_json" | jq -r '.models[]? | [(.name // ""), ((.size // 0) | tostring), (.expires_at // ""), ((.context_length // "") | tostring)] | @tsv' 2>/dev/null || true)
    loaded_count=0
    if [[ -n "$ps_lines" ]]; then
      echo "Modèle(s) actuellement en RAM :"
      while IFS=$'\t' read -r m_name m_size m_expires m_ctx; do
        [[ -n "$m_name" ]] || continue
        loaded_count=$((loaded_count + 1))
        echo "  - $m_name · occupe environ $(format_model_size "${m_size:-0}") · expiration keep-alive : ${m_expires:-inconnue}${m_ctx:+ · contexte chargé : $m_ctx}"
      done <<< "$ps_lines"
    fi
    if [[ "$loaded_count" -eq 0 ]]; then
      echo "Aucun modèle chargé en RAM : la prochaine requête paiera le temps de chargement (visible dans le TTFT)."
    fi
  else
    echo "API Ollama locale non joignable : état des modèles en RAM inconnu."
  fi
  public_url=""
  if [[ -r "$URL_FILE" ]]; then
    public_url=$(head -n 1 "$URL_FILE" 2>/dev/null || true)
  fi
  if [[ -n "$public_url" ]]; then
    echo "URL publique enregistrée : $public_url (compare son TTFT au local avec : ola bench --stream)"
  fi
  cat <<'EOF'

Actions fluidité :
  ola fluid warm [modèle]        charge un seul modèle et le garde chaud pour la session
  ola fluid preset [modèle]      affiche un preset de requête stable et rapide à copier dans ton client
  ola bench --stream [modèle]    mesure le temps avant le 1er token visible et la régularité du flux, en local et via l'URL publique
  ola fluid keepalive <durée>    change le keep-alive par défaut du serveur (ex. 30m, 1h, -1 = toujours chargé ; reset = retour à 5m), root, avec retour arrière auto
Le keep-alive ne rend pas la génération plus rapide : il supprime seulement le rechargement du modèle entre deux requêtes.
Un seul modèle chargé à la fois reste la règle sur un petit sandbox (voir ola speed).
EOF
}

warm_model_command(){
  local target=${1:-} model installed loaded payload keep_alive_value
  require_commands curl jq
  ollama_api_ready || die "Ollama API is not answering. Try: ola recover"
  installed=$(installed_model_names) || die "Could not read the installed model list from Ollama."
  [[ -n "$installed" ]] || die "No model is currently downloaded on disk. Install one first with: ola use <model>"
  model="$target"
  if [[ -z "$model" ]]; then
    model=$(saved_model_name)
  fi
  is_valid_model_name "$model" || die "Invalid model name: $model"
  model_names_contain "$installed" "$model" \
    || die "Model is not downloaded on disk: $model. Install and load it first with: ola use $model"
  keep_alive_value=$(fluid_keep_alive_for_requests)
  info "Préchauffage de $model : il restera chargé en RAM environ $keep_alive_value après cette requête."
  stop_loaded_models_except "$model"
  payload=$(jq -cn --arg model "$model" --argjson nctx "$OLLAMA_CONTEXT_LENGTH" --argjson threads "$(cpu_physical_cores)" --arg keepalive "$keep_alive_value" \
    '{model:$model, messages:[{role:"user", content:"Reply only with OK."}], stream:false, keep_alive:$keepalive, options:{num_ctx:$nctx, num_predict:8, temperature:0, num_thread:$threads}}') || die "Could not build the warm-up request."
  curl -fsS --max-time 300 http://127.0.0.1:11434/api/chat \
    -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1 \
    || die "The warm-up request failed for: $model. Check: ola logs"
  loaded=$(loaded_model_names) || die "Could not read the loaded model list after warm-up."
  model_names_contain "$loaded" "$model" || die "Ollama did not keep the model loaded after warm-up: $model"
  ok "Modèle chaud et chargé en RAM : $model (keep-alive $keep_alive_value). Pendant ta session, envoie-lui toujours le même preset : ola fluid preset $model"
  info "Pour libérer la RAM après la session : ola unload"
}

fluid_preset(){
  local target=${1:-} model installed show_json capabilities param_size think_line threads keep_alive_value show_note=""
  require_commands curl jq
  ollama_api_ready || die "Ollama API is not answering. Try: ola recover"
  installed=$(installed_model_names) || die "Could not read the installed model list from Ollama."
  [[ -n "$installed" ]] || die "No model is currently downloaded on disk. Install one first with: ola use <model>"
  model="$target"
  if [[ -z "$model" ]]; then
    model=$(saved_model_name)
  fi
  is_valid_model_name "$model" || die "Invalid model name: $model"
  model_names_contain "$installed" "$model" \
    || die "Model is not downloaded on disk: $model. Install and load it first with: ola use $model"
  show_json=$(curl -fsS --max-time 15 http://127.0.0.1:11434/api/show \
    -H 'Content-Type: application/json' -d "$(jq -cn --arg model "$model" '{model:$model}')" 2>/dev/null || true)
  capabilities=""
  param_size=""
  think_line=""
  if [[ -n "$show_json" ]]; then
    capabilities=$(printf '%s' "$show_json" | jq -r '(.capabilities // []) | join(", ")' 2>/dev/null || true)
    param_size=$(printf '%s' "$show_json" | jq -r '.details.parameter_size // empty' 2>/dev/null || true)
    if printf '%s' "$show_json" | jq -e '(.capabilities // []) | index("thinking")' >/dev/null 2>&1; then
      think_line='  "think": false,'
    fi
  else
    show_note=" (informations /api/show indisponibles : preset générique)"
  fi
  threads=$(cpu_physical_cores)
  keep_alive_value=$(fluid_keep_alive_for_requests)
  echo "--- Preset fluidité pour $model ---"
  if [[ -n "$param_size" ]]; then
    echo "Taille des paramètres : $param_size"
  fi
  if [[ -n "$capabilities" ]]; then
    echo "Capacités déclarées par Ollama : $capabilities"
  fi
  cat <<EOF
Preset stable à réutiliser tel quel pour CHAQUE requête de ta session$show_note :
{
  "model": "$model",
  "stream": true,
  "keep_alive": "$keep_alive_value",
${think_line}  "messages": [{"role": "user", "content": "Ta question ici"}],
  "options": {"num_ctx": $OLLAMA_CONTEXT_LENGTH, "num_predict": 256, "num_thread": $threads, "temperature": 0}
}
Règles qui évitent les lenteurs invisibles :
  - même num_ctx, même num_thread et même structure de requête à chaque appel : changer ces réglages entre deux requêtes peut forcer Ollama à recharger le modèle ;
  - garde le même début de prompt (system prompt + historique dans le même ordre) : la partie inchangée est relue depuis le cache du prompt au lieu d'être réévaluée ;
  - "think": false seulement si la ligne est présente ci-dessus (modèle qui déclare la capacité thinking) ; sinon ne l'envoie pas ;
  - un seul modèle par session : changer de modèle recharge à chaque fois (voir ola fluid warm).
EOF
}

rollback_keepalive_config(){
  local backup=$1 prev_existed=$2 prev_value=$3
  cp -a "$backup" "$SUP_DIR/ollama.conf" 2>/dev/null || true
  chmod 600 "$SUP_DIR/ollama.conf" 2>/dev/null || true
  if [[ "$prev_existed" -eq 1 ]]; then
    printf '%s\n' "$prev_value" > "$KEEPALIVE_FILE" 2>/dev/null || true
    chmod 600 "$KEEPALIVE_FILE" 2>/dev/null || true
  else
    rm -f "$KEEPALIVE_FILE"
  fi
  supervisor_apply >/dev/null 2>&1 || true
  supervisor_ctl start ollama >/dev/null 2>&1 || true
  wait_for_supervisor_program ollama 30 >/dev/null 2>&1 || true
  wait_for_ollama_api 30 || true
}

apply_keep_alive(){
  local target=$1 ollama_bin current installed verify_model="" backup prev_existed=0 prev_value=""
  select_supervisor_paths
  [[ -f "$SUP_DIR/ollama.conf" ]] || die "Ollama Supervisor config not found: $SUP_DIR/ollama.conf. Run setup first: ola setup"
  ollama_bin=$(ollama_bin_path) || die "Ollama binary not found. Run setup first: ola setup"
  require_commands curl jq
  ensure_service_users
  current=$(saved_keep_alive)

  if ! supervisor_program_running ollama; then
    info "Ollama is not RUNNING; starting it before applying the keep-alive default..."
    supervisor_ctl start ollama 2>/dev/null || supervisor_ctl restart ollama \
      || die "Could not start Ollama. Check: ola logs"
    wait_for_supervisor_program ollama 30 || die "Ollama did not reach RUNNING. Check: ola logs"
  fi
  wait_for_ollama_api 30 || die "Ollama API is not answering. Try: ola recover"

  installed=$(installed_model_names 2>/dev/null || true)
  if [[ -n "$installed" ]]; then
    verify_model=$(saved_model_name)
    if ! model_names_contain "$installed" "$verify_model"; then
      verify_model=$(printf '%s' "$installed" | head -n 1)
    fi
  fi

  if [[ "$target" == "$current" ]] && [[ "$(ollama_config_value OLLAMA_KEEP_ALIVE)" == "$target" ]]; then
    info "Le keep-alive serveur est déjà à $target ; vérification globale quand même."
    if [[ -n "$verify_model" ]]; then
      verify_model_chat "$verify_model" || die "Verification chat failed for the present model: $verify_model"
      ok "Keep-alive déjà actif ($target) et modèle vérifié : $verify_model"
    else
      ok "Keep-alive déjà actif : $target (aucun modèle présent à vérifier)."
    fi
    return 0
  fi

  backup=$(mktemp) || die "Could not create a temporary backup file."
  cp -a "$SUP_DIR/ollama.conf" "$backup" || die "Could not back up the Ollama Supervisor config."
  if [[ -f "$KEEPALIVE_FILE" ]]; then
    prev_existed=1
    prev_value=$(head -n 1 "$KEEPALIVE_FILE" 2>/dev/null || true)
  fi

  if [[ -n "$verify_model" ]]; then
    info "Vérification avant changement sur le modèle présent : $verify_model"
    if ! verify_model_chat "$verify_model"; then
      warn "Le modèle $verify_model ne répond pas avant le changement ; le changement continue, mais un échec identique après ne déclenchera pas de retour arrière automatique."
      verify_model=""
    fi
  fi

  info "Application du keep-alive serveur par défaut : $target (mode Pack Speed conservé : $(saved_speed_mode))"
  save_keep_alive "$target"
  write_ollama_supervisor_config "$ollama_bin" "$(saved_speed_mode)"
  if ! supervisor_apply; then
    rollback_keepalive_config "$backup" "$prev_existed" "$prev_value"
    rm -f "$backup"
    die "Supervisor rejected the new config; the previous keep-alive default was restored."
  fi
  supervisor_ctl start ollama >/dev/null 2>&1 || true
  if ! wait_for_supervisor_program ollama 30 || ! wait_for_ollama_api 60; then
    rollback_keepalive_config "$backup" "$prev_existed" "$prev_value"
    rm -f "$backup"
    die "Ollama did not come back after the keep-alive change; the previous configuration was restored."
  fi
  if [[ -n "$verify_model" ]]; then
    if ! verify_model_chat "$verify_model"; then
      rollback_keepalive_config "$backup" "$prev_existed" "$prev_value"
      rm -f "$backup"
      die "Verification chat failed after the keep-alive change for: $verify_model. The previous configuration was restored."
    fi
    ok "Modèle vérifié après changement : $verify_model"
  else
    warn "Aucun modèle présent vérifié (aucun avant le changement non plus) ; pense à tester avec : ola doctor"
  fi
  rm -f "$backup"
  ok "Keep-alive serveur par défaut : $target (fichier $KEEPALIVE_FILE, configuration Supervisor régénérée)."
  echo "Effet réel : un modèle inactif reste chargé en RAM pendant $target après sa dernière requête. La première requête suivante démarre donc sans rechargement, mais la RAM du modèle reste occupée entre-temps."
  if [[ "$target" == "-1" ]]; then
    warn "keep-alive -1 : le modèle reste chargé jusqu'à ola unload, ola use <autre modèle> ou l'arrêt d'Ollama. À réserver à une session de travail, pas à un petit sandbox laissé allumé sans surveillance RAM."
  fi
  echo "Revenir en arrière : ola fluid keepalive reset (retour à 5m). État complet : ola fluid"
}
