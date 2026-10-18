# Runs one short, identical generation request and prints a TSV line:
# total_ms, load_ms, uncached-prompt tok/s, generation tok/s, generated
# tokens, prompt tokens, cached prompt tokens (-1 when Ollama does not
# report them), response snippet. Since Ollama 0.33.3, prompt_eval_duration
# only times the prompt tokens that were NOT read from the prompt cache,
# while prompt_eval_count counts every prompt token; dividing the two
# directly inflates the prompt speed on repeated prompts, so the cached
# share is subtracted first when Ollama reports it. think_mode is "off"
# (think:false) or "default" (no think field, so thinking models may
# spend tokens thinking).
bench_run(){
  local model=$1 think_mode=$2 payload response raw total_ns load_ns p_count p_ns e_count e_ns p_cached content
  if [[ "$think_mode" == "off" ]]; then
    payload=$(jq -cn --arg model "$model" --argjson nctx "$OLLAMA_CONTEXT_LENGTH" \
      '{model:$model, messages:[{role:"user", content:"Réponds en une phrase courte : pourquoi le ciel est bleu ?"}], stream:false, think:false, options:{num_ctx:$nctx, num_predict:48, temperature:0}}') || return 1
  else
    payload=$(jq -cn --arg model "$model" --argjson nctx "$OLLAMA_CONTEXT_LENGTH" \
      '{model:$model, messages:[{role:"user", content:"Réponds en une phrase courte : pourquoi le ciel est bleu ?"}], stream:false, options:{num_ctx:$nctx, num_predict:48, temperature:0}}') || return 1
  fi
  response=$(curl -fsS --max-time 300 http://127.0.0.1:11434/api/chat \
    -H 'Content-Type: application/json' -d "$payload" 2>/dev/null) || return 1
  raw=$(printf '%s' "$response" | jq -r '[ (.total_duration // 0), (.load_duration // 0), (.prompt_eval_count // 0), (.prompt_eval_duration // 0), (.eval_count // 0), (.eval_duration // 0), (.prompt_eval_cached_count // -1) ] | @tsv' 2>/dev/null) || return 1
  IFS=$'\t' read -r total_ns load_ns p_count p_ns e_count e_ns p_cached <<< "$raw"
  content=$(printf '%s' "$response" | jq -r '.message.content // .response // ""' 2>/dev/null | tr '\n\t' '  ' | tr -d '\134' | cut -c1-90 || true)
  awk -v t="$total_ns" -v l="$load_ns" -v pc="$p_count" -v pd="$p_ns" -v ec="$e_count" -v ed="$e_ns" -v cached="$p_cached" -v c="$content" \
    'BEGIN { uncached = pc; if (cached >= 0) { uncached = pc - cached; if (uncached < 0) uncached = 0 } printf "%d\t%d\t%.1f\t%.1f\t%d\t%d\t%d\t%s", t / 1000000, l / 1000000, (pd > 0 ? uncached / (pd / 1000000000) : 0), (ed > 0 ? ec / (ed / 1000000000) : 0), ec, pc, cached, c }'
}

bench_print_line(){
  local label=$1 res=$2 total_ms load_ms p_tps e_tps e_count p_count p_cached content total_s load_s
  IFS=$'\t' read -r total_ms load_ms p_tps e_tps e_count p_count p_cached content <<< "$res"
  total_s=$(awk -v ms="${total_ms:-0}" 'BEGIN { printf "%.1f", ms / 1000 }')
  load_s=$(awk -v ms="${load_ms:-0}" 'BEGIN { printf "%.1f", ms / 1000 }')
  if [[ "${p_cached:-"-1"}" =~ ^[0-9]+$ ]]; then
    printf '%s : total %s s · chargement %s s · prompt non caché %s tok/s (%s tokens, dont %s en cache) · génération %s tok/s (%s tokens générés)\n' \
      "$label" "$total_s" "$load_s" "${p_tps:-0}" "${p_count:-0}" "$p_cached" "${e_tps:-0}" "${e_count:-0}"
  else
    printf '%s : total %s s · chargement %s s · prompt %s tok/s · génération %s tok/s (%s tokens générés)\n' \
      "$label" "$total_s" "$load_s" "${p_tps:-0}" "${e_tps:-0}" "${e_count:-0}"
  fi
  if [[ -n "${content:-}" ]]; then
    printf '   Réponse : %s\n' "$content"
  fi
}

# Prints installed model names with the saved default moved to the end, so
# a global benchmark finishes on the model the user normally uses.
ordered_present_model_names(){
  local names=$1 default_model=$2 name default_norm
  default_norm=$(normalize_model_name "$default_model")
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$(normalize_model_name "$name")" == "$default_norm" ]] || printf '%s\n' "$name"
  done <<< "$names"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$(normalize_model_name "$name")" == "$default_norm" ]] && printf '%s\n' "$name"
  done <<< "$names"
  return 0
}

# Populated by bench_one_model for bench_summary_for_last.
LAST_BENCH_DEFAULT_RES=""
LAST_BENCH_OFF_RES=""
LAST_BENCH_HAVE_DEFAULT=0
LAST_BENCH_HAVE_OFF=0

bench_one_model(){
  local model=$1 res_default="" res_off="" have_default=0 have_off=0 d_total o_total gain
  LAST_BENCH_DEFAULT_RES=""
  LAST_BENCH_OFF_RES=""
  LAST_BENCH_HAVE_DEFAULT=0
  LAST_BENCH_HAVE_OFF=0

  info "Run 1/2 : thinking par défaut (sans think:false)..."
  if res_default=$(bench_run "$model" default); then
    have_default=1
    bench_print_line "Thinking par défaut" "$res_default"
  else
    err "Le run avec thinking par défaut a échoué pour le modèle : $model"
  fi
  echo
  info "Run 2/2 : think:false..."
  if res_off=$(bench_run "$model" off); then
    have_off=1
    bench_print_line "think:false        " "$res_off"
  else
    warn "think:false a été refusé par ce modèle (modèle sans mode réflexion, probablement) : ignore ce réglage pour lui."
  fi

  LAST_BENCH_DEFAULT_RES="$res_default"
  LAST_BENCH_OFF_RES="$res_off"
  LAST_BENCH_HAVE_DEFAULT="$have_default"
  LAST_BENCH_HAVE_OFF="$have_off"
  [[ "$have_default" -eq 1 || "$have_off" -eq 1 ]] || return 1

  if [[ "$have_default" -eq 1 && "$have_off" -eq 1 ]]; then
    d_total=$(printf '%s' "$res_default" | cut -f1)
    o_total=$(printf '%s' "$res_off" | cut -f1)
    if [[ "$o_total" =~ ^[0-9]+$ && "$d_total" =~ ^[0-9]+$ && "$d_total" -gt 0 && "$o_total" -lt "$d_total" ]]; then
      gain=$(awk -v d="$d_total" -v o="$o_total" 'BEGIN { printf "%.0f", (d - o) / d * 100 }')
      ok "Verdict mesuré pour $model : think:false a été environ ${gain}% plus rapide sur ce test."
    elif [[ "$o_total" =~ ^[0-9]+$ && "$d_total" =~ ^[0-9]+$ && "$o_total" -gt "$d_total" ]]; then
      warn "Verdict mesuré pour $model : think:false n'a pas été plus rapide sur ce test (le premier run inclut parfois le chargement ; relance le bench pour confirmer)."
    else
      info "Verdict mesuré pour $model : pas de différence nette entre les deux runs sur ce test."
    fi
  elif [[ "$have_off" -eq 1 ]]; then
    warn "Verdict pour $model : seul le run think:false a réussi ; compare avec prudence."
  else
    warn "Verdict pour $model : think:false indisponible/refusé ; utilise le comportement par défaut de ce modèle."
  fi
  return 0
}

bench_summary_for_last(){
  local model=$1 d_tps="-" o_tps="-" d_total o_total conclusion
  if [[ "$LAST_BENCH_HAVE_DEFAULT" -eq 1 ]]; then
    d_tps=$(printf '%s' "$LAST_BENCH_DEFAULT_RES" | cut -f4)
  fi
  if [[ "$LAST_BENCH_HAVE_OFF" -eq 1 ]]; then
    o_tps=$(printf '%s' "$LAST_BENCH_OFF_RES" | cut -f4)
  fi
  if [[ "$LAST_BENCH_HAVE_DEFAULT" -eq 1 && "$LAST_BENCH_HAVE_OFF" -eq 1 ]]; then
    d_total=$(printf '%s' "$LAST_BENCH_DEFAULT_RES" | cut -f1)
    o_total=$(printf '%s' "$LAST_BENCH_OFF_RES" | cut -f1)
    if [[ "$o_total" =~ ^[0-9]+$ && "$d_total" =~ ^[0-9]+$ && "$o_total" -lt "$d_total" ]]; then
      conclusion="think:false plus rapide sur ce test"
    elif [[ "$o_total" =~ ^[0-9]+$ && "$d_total" =~ ^[0-9]+$ && "$o_total" -gt "$d_total" ]]; then
      conclusion="pas de gain think:false mesuré"
    else
      conclusion="pas de différence nette"
    fi
  elif [[ "$LAST_BENCH_HAVE_OFF" -eq 1 ]]; then
    conclusion="seul think:false a répondu"
  elif [[ "$LAST_BENCH_HAVE_DEFAULT" -eq 1 ]]; then
    conclusion="think:false refusé/non applicable"
  else
    conclusion="ÉCHEC des deux runs"
  fi
  printf '%s | génération défaut %s tok/s | génération think:false %s tok/s | %s' "$model" "$d_tps" "$o_tps" "$conclusion"
}

run_bench(){
  local requested=${1:-} installed loaded mem_kb base public_url threads saved_default example_model
  local -a present_models=() models_to_bench=() summary_lines=()
  local model ordered successes=0 failures=0 global=0 idx
  require_commands curl jq
  ollama_api_ready || die "Ollama API is not answering, so the benchmark cannot run. Try: ola recover"
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
    example_model="$requested"
  else
    global=1
    models_to_bench=("${present_models[@]}")
    example_model="${models_to_bench[$((${#models_to_bench[@]} - 1))]}"
    if model_names_contain "$installed" "$saved_default"; then
      example_model="$saved_default"
    fi
  fi
  threads=$(cpu_physical_cores)

  echo "--- Ola bench ---"
  if [[ "$global" -eq 1 ]]; then
    info "Portée globale : ${#models_to_bench[@]} modèle(s) présent(s) sur le disque, testés un par un."
    info "Modèles pris en compte : $(printf '%s' "$installed" | tr '\n' ' ')"
    info "Le modèle par défaut est testé en dernier afin de terminer avec lui : $example_model"
  else
    info "Portée ciblée : un seul modèle."
  fi
  info "CPU : $(cpu_logical_cores) logique(s), environ $threads physique(s) — $(cpu_speed_summary)"
  mem_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    info "RAM disponible : environ $((mem_kb / 1024)) MB"
  fi
  echo "Chaque modèle est testé séparément ; les autres modèles chargés sont déchargés de la RAM avant son test. Aucun fichier de modèle n'est modifié ni supprimé."
  echo "Test identique pour les deux runs de chaque modèle : même question courte, 48 tokens max, num_ctx $OLLAMA_CONTEXT_LENGTH, température 0."

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
    if bench_one_model "$model"; then
      successes=$((successes + 1))
    else
      failures=$((failures + 1))
    fi
    summary_lines+=("$(bench_summary_for_last "$model")")
  done

  if [[ "$global" -eq 1 ]]; then
    echo
    echo "--- Synthèse globale ---"
    printf '%s\n' "${summary_lines[@]}"
  fi
  if [[ "$successes" -eq 0 ]]; then
    die "Benchmark failed for every tested model. Check: ola logs"
  fi
  if [[ "$failures" -gt 0 ]]; then
    warn "Benchmark terminé avec $failures échec(s) et $successes succès. Les modèles en échec sont signalés dans la synthèse."
  fi

  base="http://127.0.0.1:11434"
  if [[ -r "$URL_FILE" ]]; then
    public_url=$(head -n 1 "$URL_FILE" 2>/dev/null || true)
    [[ -n "$public_url" ]] && base="$public_url"
  fi
  cat <<EOF

Conseils vitesse, du plus efficace au plus fin :
  1. Questions simples : envoie "think": false (mesuré ci-dessus, modèle par modèle) et limite la longueur avec options.num_predict (ex. 128 ou 256). Si un modèle refuse "think": false, ignore ce réglage pour ce modèle précis.
  2. Utilise "stream": true dans tes applis : la génération n'est pas plus rapide, mais les tokens s'affichent au fur et à mesure.
  3. Côté client, essaie options.num_thread ≈ $threads (cœurs physiques estimés) et compare ; options.num_batch ne sert surtout qu'aux très longs prompts.
  4. Garde un seul modèle chargé (ola ps / ola unload) : sur un petit sandbox, la RAM libre évite les lenteurs.
  5. Le keep-alive serveur actuel ($(saved_keep_alive)) garde le modèle en RAM après chaque requête : réponses suivantes plus rapides, mais RAM occupée. ola fluid warm garde un modèle chaud 30 minutes pour une session ; ola unload libère tout de suite. Fluidité mesurée (1er token, local et public) : ola bench --stream ; preset stable à copier dans ton client : ola fluid preset.

Exemple rapide à copier (modèle utilisé dans l'exemple : $example_model ; remplace l'URL par la tienne si besoin) :
curl -fsS $base/api/chat -H 'Content-Type: application/json' -d '{
  "model": "$example_model",
  "messages": [{"role": "user", "content": "Dis bonjour en une phrase."}],
  "stream": true,
  "think": false,
  "options": {"num_predict": 128, "num_thread": $threads}
}'
EOF
  [[ "$failures" -eq 0 ]]
}
