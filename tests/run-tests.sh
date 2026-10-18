#!/usr/bin/env bash
# Isolated stub tests for the generated ola artifact and the Textual TUI.
#
# The Bash tests run inside a user/mount namespace with fake /etc, /var/log
# and /usr/local directories plus stub curl/Ollama/Supervisor commands. They
# never install or contact a real Ollama, cloudflared, Supervisor or tunnel.
#
# Optional environment:
#   SHELLCHECK=/path/to/shellcheck       also run ShellCheck when present
#   OLA_TUI_TEST_PYTHON=/path/to/python  Python with Textual for pilot tests
#   KEEP_TEST_WORK=1                     keep the temporary test directory

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARTIFACT=${OLA_ARTIFACT:-"$ROOT/ollama-cloudflare-setup.sh"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ola-tests.XXXXXX")
CASE_DIR="$WORK/case"
OUT="$WORK/output"
mkdir -p "$OUT"

cleanup(){
  if [[ "${KEEP_TEST_WORK:-0}" == "1" ]]; then
    echo "Test work kept: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

export TEST_STATE="$CASE_DIR/state"
export TEST_ETC="$CASE_DIR/etc"
export TEST_VARLOG="$CASE_DIR/varlog"
export TEST_LOCAL="$CASE_DIR/local"
export TEST_HOME_OLLAMA="$CASE_DIR/ollama-home"
export OLA_ARTIFACT="$ARTIFACT"
export HOME="$CASE_DIR/home"
export PATH="$ROOT/tests/stub/bin-model:$ROOT/tests/stub/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

pass=0
fail=0

check(){
  local file=$1 needle=$2 label=$3
  if grep -Fq -- "$needle" "$file"; then
    echo "PASS: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: $label (missing: $needle; output: $file)"
    fail=$((fail + 1))
  fi
}

check_absent(){
  local file=$1 needle=$2 label=$3
  if grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $label (unexpected: $needle; output: $file)"
    fail=$((fail + 1))
  else
    echo "PASS: $label"
    pass=$((pass + 1))
  fi
}

check_file(){
  local file=$1 label=$2
  if [[ -f "$file" ]]; then
    echo "PASS: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: $label (missing file: $file)"
    fail=$((fail + 1))
  fi
}

check_file_contains(){
  local file=$1 needle=$2 label=$3
  if [[ -f "$file" ]] && grep -Fq -- "$needle" "$file"; then
    echo "PASS: $label"
    pass=$((pass + 1))
  else
    echo "FAIL: $label (missing '$needle' in $file)"
    fail=$((fail + 1))
  fi
}

reset_case(){
  rm -rf "$CASE_DIR"
  mkdir -p \
    "$TEST_STATE" "$TEST_ETC" "$TEST_VARLOG/supervisor" \
    "$TEST_LOCAL/bin" "$TEST_LOCAL/lib" "$TEST_HOME_OLLAMA" "$HOME"
  cp -a "$ROOT/tests/fixtures/etc/." "$TEST_ETC/"
  printf 'qwen3:1.7b\nllama3.2:1b\n' > "$TEST_STATE/installed-models"
  printf 'qwen3:1.7b\n' > "$TEST_STATE/loaded-models"
  : > "$TEST_STATE/model-order.log"
  : > "$TEST_STATE/bench-payloads.log"
  : > "$TEST_STATE/calls.log"
  : > "$TEST_STATE/supervisor-calls.log"
  touch \
    "$TEST_STATE/ollama.running" \
    "$TEST_STATE/cloudflared-ollama.running" \
    "$TEST_STATE/ollama-watchdog.running"
  printf 'qwen3:1.7b\n' > "$TEST_ETC/ollama-cloudflare-model"
  printf 'https://fresh-quick.trycloudflare.com\n' > "$TEST_ETC/ollama-cloudflare-url"
  rm -f "$TEST_ETC/ollama-cloudflare-speed" "$TEST_ETC/ollama-cloudflare-keepalive"
  for log in ollama.log ollama-error.log cloudflared-ollama.log cloudflared-ollama-error.log ollama-watchdog.log ollama-watchdog-error.log; do
    : > "$TEST_VARLOG/supervisor/$log"
  done
}

run(){
  unshare -rm bash "$ROOT/tests/stub/runner.sh" "$@"
}

if ! command -v unshare >/dev/null 2>&1; then
  echo "FAIL: unshare is required for the isolated Bash tests" >&2
  exit 1
fi
if ! unshare -rm true 2>/dev/null; then
  echo "FAIL: user/mount namespaces are unavailable in this environment" >&2
  exit 1
fi

# --- Build and static checks -------------------------------------------------
built="$WORK/built-artifact.sh"
if "$ROOT/build.sh" "$built" > "$OUT/build.log" 2>&1 && cmp -s "$built" "$ARTIFACT"; then
  echo "PASS: build.sh reproduces the committed artifact"
  pass=$((pass + 1))
else
  echo "FAIL: build.sh output differs from the committed artifact (see $OUT/build.log)"
  fail=$((fail + 1))
fi

if bash -n "$ARTIFACT"; then
  echo "PASS: generated artifact syntax"
  pass=$((pass + 1))
else
  echo "FAIL: generated artifact syntax"
  fail=$((fail + 1))
fi

if [[ -n "${SHELLCHECK:-}" && -x "${SHELLCHECK:-}" ]]; then
  if "$SHELLCHECK" "$ARTIFACT" "$ROOT/build.sh" > "$OUT/shellcheck.log" 2>&1; then
    echo "PASS: ShellCheck"
    pass=$((pass + 1))
  else
    echo "FAIL: ShellCheck (see $OUT/shellcheck.log)"
    fail=$((fail + 1))
  fi
else
  echo "SKIP: ShellCheck (set SHELLCHECK=/path/to/shellcheck to enable)"
fi

bash "$ARTIFACT" --help > "$OUT/help.log" 2>&1
check "$OUT/help.log" "ola tui opens" "help documents ola tui"
check "$OUT/help.log" "ola bench --stream" "help documents streaming bench"
check "$OUT/help.log" "ola update downloads" "help documents ola update"
check "$OUT/help.log" "ola setup default uses" "help documents quick setup"
check "$OUT/help.log" "ola colab status/save/restore" "help documents Colab state commands"
check_file "$ROOT/colab/Ola-Colab.ipynb" "Colab notebook is present"
check_file_contains "$ROOT/colab/Ola-Colab.ipynb" "OLA_COLAB_STATE_DIR" "Colab notebook configures persistent Drive state"
check_file_contains "$ROOT/colab/Ola-Colab.ipynb" "setup default" "Colab notebook runs the end-to-end quick setup"
if (cd "$ROOT" && sha256sum -c ollama-cloudflare-setup.sh.sha256 > "$OUT/artifact-sha256.log" 2>&1); then
  echo "PASS: published artifact SHA-256 matches"
  pass=$((pass + 1))
else
  echo "FAIL: published artifact SHA-256 mismatch (see $OUT/artifact-sha256.log)"
  fail=$((fail + 1))
fi

# --- Fluid status / warm / preset --------------------------------------------
reset_case
run fluid > "$OUT/fluid-status.log" 2>&1; echo "fluid status exit=$?"
check "$OUT/fluid-status.log" "--- Ola fluidité ---" "fluid status header"
check "$OUT/fluid-status.log" "Keep-alive serveur enregistré : 5m" "fluid default keep-alive"
check "$OUT/fluid-status.log" "qwen3:1.7b · occupe environ" "fluid loaded model detail"

reset_case
run fluid warm llama3.2:1b > "$OUT/fluid-warm.log" 2>&1; echo "fluid warm exit=$?"
check "$OUT/fluid-warm.log" "Modèle chaud et chargé en RAM : llama3.2:1b" "warm loads target"
check_file_contains "$TEST_STATE/bench-payloads.log" '"keep_alive":"30m"' "warm uses 30m keep-alive"
if grep -Fxq 'qwen3:1.7b' "$TEST_STATE/loaded-models"; then
  echo "FAIL: warm left another model loaded"
  fail=$((fail + 1))
else
  echo "PASS: warm unloads other model"
  pass=$((pass + 1))
fi

reset_case
run fluid preset qwen3:1.7b > "$OUT/preset-qwen.log" 2>&1; echo "preset qwen exit=$?"
check "$OUT/preset-qwen.log" '"think": false,' "preset includes think:false for thinking model"
check "$OUT/preset-qwen.log" '"stream": true' "preset enables streaming"
run fluid preset llama3.2:1b > "$OUT/preset-llama.log" 2>&1; echo "preset llama exit=$?"
check_absent "$OUT/preset-llama.log" '"think": false,' "preset omits think:false without thinking capability"

# --- Global classic and streaming benches ------------------------------------
reset_case
run bench > "$OUT/bench-global.log" 2>&1; echo "classic bench exit=$?"
check "$OUT/bench-global.log" "Portée globale : 2 modèle(s)" "classic bench is global"
check "$OUT/bench-global.log" "=== Modèle 1/2 : llama3.2:1b ===" "classic bench orders non-default first"
check "$OUT/bench-global.log" "=== Modèle 2/2 : qwen3:1.7b ===" "classic bench orders default last"
check "$OUT/bench-global.log" "prompt 100.0 tok/s" "classic bench keeps uncached fallback when cache is unreported"

reset_case
run bench --stream > "$OUT/bench-stream.log" 2>&1; echo "stream bench exit=$?"
check "$OUT/bench-stream.log" "Ola bench streaming (fluidité)" "stream bench header"
check "$OUT/bench-stream.log" "Local  (think:false)" "stream bench local result"
check "$OUT/bench-stream.log" "Public (think:false)" "stream bench public result"
check "$OUT/bench-stream.log" "prompt non caché 25.0 tok/s" "stream prompt excludes cached tokens"
check "$OUT/bench-stream.log" "Synthèse fluidité" "stream bench summary"

reset_case
run bench --stream qwen3:1.7b > "$OUT/bench-stream-one.log" 2>&1; echo "targeted stream exit=$?"
check "$OUT/bench-stream-one.log" "Portée ciblée" "targeted stream scope"
check_absent "$OUT/bench-stream-one.log" "=== Modèle 1/1 : llama3.2:1b ===" "targeted stream excludes other model"

# --- Global speed and keep-alive ---------------------------------------------
reset_case
run speed apply > "$OUT/speed-apply.log" 2>&1; echo "speed apply exit=$?"
check "$OUT/speed-apply.log" "Verification passed for 2/2" "global speed apply verifies all models"
check_file_contains "$TEST_ETC/supervisor/conf.d/ollama.conf" 'OLLAMA_FLASH_ATTENTION="1"' "speed config enables Flash Attention"

run fluid keepalive 30m > "$OUT/keepalive.log" 2>&1; echo "keepalive exit=$?"
check "$OUT/keepalive.log" "Keep-alive serveur par défaut : 30m" "keep-alive applies"
check_file_contains "$TEST_ETC/supervisor/conf.d/ollama.conf" 'OLLAMA_KEEP_ALIVE="30m"' "keep-alive written to Supervisor config"
check_file_contains "$TEST_ETC/supervisor/conf.d/ollama.conf" 'OLLAMA_FLASH_ATTENTION="1"' "keep-alive preserves Pack Speed"
check_file "$TEST_LOCAL/lib/ollama-cloudflare/ola_tui.py" "root command installs embedded TUI application"
check_file_contains "$TEST_LOCAL/lib/ollama-cloudflare/ola_tui.py" "class OlaTui" "embedded TUI application is complete"
check_file "$TEST_LOCAL/lib/ollama-cloudflare/tui-requirements.txt" "root command installs TUI requirements"
if cmp -s "$TEST_LOCAL/lib/ollama-cloudflare/ola_tui.py" "$ROOT/tui/ola_tui.py"; then
  echo "PASS: extracted TUI application matches tui/ola_tui.py"
  pass=$((pass + 1))
else
  echo "FAIL: extracted TUI application differs from tui/ola_tui.py"
  fail=$((fail + 1))
fi
if cmp -s "$TEST_LOCAL/lib/ollama-cloudflare/tui-requirements.txt" "$ROOT/tui/requirements.txt"; then
  echo "PASS: extracted TUI requirements match tui/requirements.txt"
  pass=$((pass + 1))
else
  echo "FAIL: extracted TUI requirements differ from tui/requirements.txt"
  fail=$((fail + 1))
fi

run fluid keepalive reset > "$OUT/keepalive-reset.log" 2>&1; echo "keepalive reset exit=$?"
check_file_contains "$TEST_ETC/supervisor/conf.d/ollama.conf" 'OLLAMA_KEEP_ALIVE="5m"' "keep-alive reset restores 5m"

reset_case
run fluid keepalive nonsense > "$OUT/keepalive-invalid.log" 2>&1; invalid_exit=$?
echo "invalid keepalive exit=$invalid_exit"
check "$OUT/keepalive-invalid.log" "Invalid keep-alive duration" "invalid keep-alive rejected"

# --- TUI shell integration -----------------------------------------------------
reset_case
run tui install > "$OUT/tui-install.log" 2>&1; echo "tui install exit=$?"
check "$OUT/tui-install.log" "TUI installed: Textual 8.2.8" "TUI install uses isolated pinned environment"
check_file "$TEST_LOCAL/lib/ollama-cloudflare/tui-venv/bin/python" "TUI install creates isolated Python"
run tui status > "$OUT/tui-status-ready.log" 2>&1; echo "ready tui status exit=$?"
check "$OUT/tui-status-ready.log" "TUI prête" "TUI status reports ready environment"

reset_case
run tui status > "$OUT/tui-status.log" 2>&1; tui_status_exit=$?
echo "tui status without venv exit=$tui_status_exit"
check "$OUT/tui-status.log" "TUI non prête" "TUI status reports missing environment"
if [[ "$tui_status_exit" -ne 0 ]]; then
  echo "PASS: TUI status returns nonzero when not ready"
  pass=$((pass + 1))
else
  echo "FAIL: TUI status should return nonzero when not ready"
  fail=$((fail + 1))
fi

run tui > "$OUT/tui-noninteractive.log" 2>&1; tui_launch_exit=$?
echo "non-interactive tui exit=$tui_launch_exit"
check "$OUT/tui-noninteractive.log" "requires an interactive terminal" "TUI refuses non-interactive launch"

# --- Doctor --------------------------------------------------------------------
reset_case
run doctor > "$OUT/doctor.log" 2>&1; echo "doctor exit=$?"
check "$OUT/doctor.log" "Textual TUI is not installed/ready" "doctor reports optional TUI state"
check "$OUT/doctor.log" "Doctor summary: 0 failure(s)" "doctor has no failures"

# --- Quick setup arguments ---------------------------------------------------------
reset_case
run setup qwen3:1.7b > "$OUT/setup-missing-mode.log" 2>&1; setup_missing_exit=$?
echo "setup missing mode exit=$setup_missing_exit"
check "$OUT/setup-missing-mode.log" "only 'ola setup default' is supported" "quick setup requires a tunnel mode"
if [[ "$setup_missing_exit" -ne 0 ]]; then
  echo "PASS: quick setup missing mode exits nonzero"
  pass=$((pass + 1))
else
  echo "FAIL: quick setup missing mode should exit nonzero"
  fail=$((fail + 1))
fi

run setup qwen3:1.7b 3 > "$OUT/setup-invalid-mode.log" 2>&1; setup_invalid_exit=$?
echo "setup invalid mode exit=$setup_invalid_exit"
check "$OUT/setup-invalid-mode.log" "Invalid tunnel mode" "quick setup rejects an unknown tunnel mode"

run setup qwen3:1.7b 1 ollama.example.com > "$OUT/setup-quick-hostname.log" 2>&1; setup_quick_host_exit=$?
echo "setup quick with hostname exit=$setup_quick_host_exit"
check "$OUT/setup-quick-hostname.log" "only supported with Named Tunnel" "quick setup rejects a hostname with Quick Tunnel"

reset_case
run setup default > "$OUT/setup-default.log" 2>&1; setup_default_exit=$?
echo "setup default exit=$setup_default_exit"
check "$OUT/setup-default.log" "Setup rapide : modèle qwen3:1.7b · tunnel 1" "setup default selects the built-in model and Quick Tunnel"
check "$OUT/setup-default.log" "Quick Tunnel URL: https://fresh-quick.trycloudflare.com" "setup default configures a Quick Tunnel"
check_file_contains "$TEST_ETC/ollama-cloudflare-model" "qwen3:1.7b" "setup default saves the built-in default model"
check_file_contains "$TEST_ETC/ollama-cloudflare-url" "https://fresh-quick.trycloudflare.com" "setup default saves the Quick Tunnel URL"
check_file_contains "$TEST_ETC/supervisor/conf.d/ollama.conf" "user=ollama" "standard setup keeps the dedicated Ollama user"
check_absent "$TEST_ETC/supervisor/conf.d/ollama.conf" "OLLAMA_MODELS=" "standard setup does not force a Colab models directory"
check_absent "$TEST_ETC/supervisor/conf.d/ollama.conf" "LD_LIBRARY_PATH=" "standard setup does not add the Colab NVIDIA library path"

reset_case
run setup llama3.2:1b account ollama.example.com > "$OUT/setup-named.log" 2>&1; setup_named_exit=$?
echo "setup named exit=$setup_named_exit"
check "$OUT/setup-named.log" "Setup rapide : modèle llama3.2:1b · tunnel 2" "quick setup accepts a model and account mode"
check "$OUT/setup-named.log" "Named Tunnel preset: tunnel name 'ollama-vps', hostname 'ollama.example.com'." "quick setup uses the preset Named Tunnel name and hostname"
check_file_contains "$TEST_ETC/ollama-cloudflare-model" "llama3.2:1b" "quick setup saves the requested model"
check_file_contains "$TEST_ETC/ollama-cloudflare-url" "https://ollama.example.com" "quick setup saves the Named Tunnel URL"
check_file_contains "$TEST_ETC/cloudflared/config.yml" "hostname: ollama.example.com" "quick setup writes the Named Tunnel hostname"

reset_case
printf '%s\n' "ollama.example.com" | run setup qwen3:0.6b named > "$OUT/setup-named-prompt.log" 2>&1; setup_named_prompt_exit=$?
echo "setup named prompt exit=$setup_named_prompt_exit"
check "$OUT/setup-named-prompt.log" "Named Tunnel preset: tunnel name 'ollama-vps'." "quick Named setup asks only for the missing hostname"
check_file_contains "$TEST_ETC/ollama-cloudflare-url" "https://ollama.example.com" "quick Named setup uses the prompted hostname"

reset_case
printf '%s\n%s\n' "qwen3:0.6b" "1" | run setup > "$OUT/setup-interactive.log" 2>&1; setup_interactive_exit=$?
echo "setup interactive exit=$setup_interactive_exit"
check "$OUT/setup-interactive.log" "Quick Tunnel URL: https://fresh-quick.trycloudflare.com" "interactive setup still prompts for model and tunnel"
check_file_contains "$TEST_ETC/ollama-cloudflare-model" "qwen3:0.6b" "interactive setup saves the prompted model"

# --- Google Colab profile ---------------------------------------------------------
export OLA_COLAB=1
export OLA_COLAB_STATE_DIR="$TEST_STATE/colab-state"
export OLLAMA_MODELS="$TEST_STATE/colab-state/models"
reset_case
run setup default > "$OUT/setup-colab.log" 2>&1; setup_colab_exit=$?
echo "setup colab exit=$setup_colab_exit"
check "$OUT/setup-colab.log" "État Colab sauvegardé" "Colab setup saves persistent state"
check_file_contains "$TEST_ETC/supervisor/conf.d/ollama.conf" "user=root" "Colab Supervisor runs Ollama as root"
check_file_contains "$TEST_ETC/supervisor/conf.d/cloudflared-ollama.conf" "user=root" "Colab Supervisor runs cloudflared as root"
check_file_contains "$TEST_ETC/supervisor/conf.d/ollama.conf" "OLLAMA_MODELS=\"$TEST_STATE/colab-state/models\"" "Colab setup writes the persistent models directory"
check_file_contains "$TEST_ETC/supervisor/conf.d/ollama.conf" "LD_LIBRARY_PATH=\"/usr/lib64-nvidia" "Colab setup exposes NVIDIA libraries to Ollama"
check_file_contains "$TEST_STATE/colab-state/config/ollama-cloudflare-model" "qwen3:1.7b" "Colab state keeps the default model setting"
check_file "$TEST_ETC/ollama-cloudflare-colab" "Colab setup writes the runtime profile marker"
run colab status > "$OUT/colab-status.log" 2>&1; colab_status_exit=$?
echo "colab status exit=$colab_status_exit"
check "$OUT/colab-status.log" "Mode Colab : activé" "Colab status reports the active Colab profile"
check "$OUT/colab-status.log" "Dossier modèles Ollama : $TEST_STATE/colab-state/models" "Colab status reports the persistent models directory"
unset OLA_COLAB OLA_COLAB_STATE_DIR OLLAMA_MODELS
run colab status > "$OUT/colab-status-marker.log" 2>&1; colab_marker_status_exit=$?
echo "colab marker status exit=$colab_marker_status_exit"
check "$OUT/colab-status-marker.log" "Mode Colab : activé" "Colab profile survives a later shell through the runtime marker"
check "$OUT/colab-status-marker.log" "Dossier modèles Ollama : $TEST_STATE/colab-state/models" "Colab marker restores the persistent state path"
printf 'qwen3:0.6b\n' > "$TEST_ETC/ollama-cloudflare-model"
run colab restore > "$OUT/colab-restore.log" 2>&1; colab_restore_exit=$?
echo "colab restore exit=$colab_restore_exit"
check_file_contains "$TEST_ETC/ollama-cloudflare-model" "qwen3:1.7b" "Colab restore brings back the saved default model"

# --- Self-update -----------------------------------------------------------------
export OLA_UPDATE_URL="https://updates.example.test/ollama-cloudflare-setup.sh"
export OLA_UPDATE_SHA256_URL="https://updates.example.test/ollama-cloudflare-setup.sh.sha256"

reset_case
run start > "$OUT/update-prepare.log" 2>&1
cp "$ARTIFACT" "$TEST_STATE/update-artifact.sh"
printf '\n# ola update test candidate\n' >> "$TEST_STATE/update-artifact.sh"
update_candidate_hash=$(sha256sum "$TEST_STATE/update-artifact.sh" | awk 'NR == 1 { print $1 }')
printf '%s  ollama-cloudflare-setup.sh\n' "$update_candidate_hash" > "$TEST_STATE/update-artifact.sha256"
update_install_dir="$TEST_LOCAL/lib/ollama-cloudflare"
mkdir -p "$update_install_dir/update.lock"
printf '999999\n' > "$update_install_dir/update.lock/pid"
touch -d '2 hours ago' "$update_install_dir/update.lock"
run update > "$OUT/update.log" 2>&1; update_exit=$?
echo "update exit=$update_exit"
check "$OUT/update.log" "Mise à jour de ola installée" "ola update installs a verified candidate"
if cmp -s "$TEST_STATE/update-artifact.sh" "$update_install_dir/ollama-cloudflare-setup.sh"; then
  echo "PASS: ola update replaces the installed artifact"
  pass=$((pass + 1))
else
  echo "FAIL: ola update did not replace the installed artifact"
  fail=$((fail + 1))
fi
check_file "$update_install_dir/backup/ollama-cloudflare-setup.sh.bak" "ola update keeps the previous artifact"
check_absent "$update_install_dir/backup/ollama-cloudflare-setup.sh.bak" "ola update test candidate" "ola update backup is the previous version"
if [[ ! -d "$update_install_dir/update.lock" ]]; then
  echo "PASS: ola update releases its lock and cleans a stale lock"
  pass=$((pass + 1))
else
  echo "FAIL: ola update left its lock behind"
  fail=$((fail + 1))
fi

run update > "$OUT/update-current.log" 2>&1; update_current_exit=$?
echo "update already-current exit=$update_current_exit"
check "$OUT/update-current.log" "ola est déjà à jour" "ola update reports an already-current artifact"

sleep 20 &
update_lock_pid=$!
mkdir -p "$update_install_dir/update.lock"
printf '%s\n' "$update_lock_pid" > "$update_install_dir/update.lock/pid"
run update > "$OUT/update-locked.log" 2>&1; update_locked_exit=$?
kill "$update_lock_pid" 2>/dev/null || true
wait "$update_lock_pid" 2>/dev/null || true
rm -rf "$update_install_dir/update.lock"
echo "update locked exit=$update_locked_exit"
check "$OUT/update-locked.log" "déjà en cours" "ola update refuses a concurrent update"

reset_case
run start > "$OUT/update-bad-prepare.log" 2>&1
update_before_hash=$(sha256sum "$update_install_dir/ollama-cloudflare-setup.sh" | awk 'NR == 1 { print $1 }')
cp "$ARTIFACT" "$TEST_STATE/update-artifact.sh"
printf '\n# ola update bad checksum candidate\n' >> "$TEST_STATE/update-artifact.sh"
printf '%s  ollama-cloudflare-setup.sh\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$TEST_STATE/update-artifact.sha256"
run update > "$OUT/update-bad-checksum.log" 2>&1; update_bad_exit=$?
update_after_hash=$(sha256sum "$update_install_dir/ollama-cloudflare-setup.sh" | awk 'NR == 1 { print $1 }')
echo "update bad checksum exit=$update_bad_exit"
check "$OUT/update-bad-checksum.log" "SHA-256 différent" "ola update rejects a checksum mismatch"
if [[ "$update_bad_exit" -ne 0 && "$update_before_hash" == "$update_after_hash" ]]; then
  echo "PASS: rejected update leaves the installed artifact unchanged"
  pass=$((pass + 1))
else
  echo "FAIL: rejected update changed the installed artifact or exited zero"
  fail=$((fail + 1))
fi

reset_case
run start > "$OUT/update-rollback-prepare.log" 2>&1
cp "$ARTIFACT" "$TEST_STATE/update-artifact.sh"
printf '\n# ola update rollback candidate\n' >> "$TEST_STATE/update-artifact.sh"
update_candidate_hash=$(sha256sum "$TEST_STATE/update-artifact.sh" | awk 'NR == 1 { print $1 }')
printf '%s  ollama-cloudflare-setup.sh\n' "$update_candidate_hash" > "$TEST_STATE/update-artifact.sha256"
touch "$TEST_STATE/fail-restart"
run update > "$OUT/update-rollback.log" 2>&1; update_rollback_exit=$?
echo "update rollback exit=$update_rollback_exit"
check "$OUT/update-rollback.log" "Mise à jour échouée" "ola update reports rollback after restart failure"
check_absent "$update_install_dir/ollama-cloudflare-setup.sh" "ola update rollback candidate" "ola update rollback restores the previous artifact"
if [[ "$update_rollback_exit" -ne 0 ]]; then
  echo "PASS: failed post-update restart exits nonzero"
  pass=$((pass + 1))
else
  echo "FAIL: failed post-update restart should exit nonzero"
  fail=$((fail + 1))
fi
unset OLA_UPDATE_URL OLA_UPDATE_SHA256_URL

# --- Python/Textual pilot tests ------------------------------------------------
TUI_PYTHON=${OLA_TUI_TEST_PYTHON:-python3}
if "$TUI_PYTHON" -c 'import textual' >/dev/null 2>&1; then
  if "$TUI_PYTHON" "$ROOT/tests/run-tui-tests.py" > "$OUT/tui-pilot.log" 2>&1; then
    echo "PASS: Textual pilot tests"
    pass=$((pass + 1))
  else
    echo "FAIL: Textual pilot tests (see $OUT/tui-pilot.log)"
    sed -n '1,160p' "$OUT/tui-pilot.log" >&2 || true
    fail=$((fail + 1))
  fi
else
  echo "SKIP: Textual pilot tests (set OLA_TUI_TEST_PYTHON to a Python with Textual)"
fi

echo "=== OLA TESTS: pass=$pass fail=$fail ==="
[[ "$fail" -eq 0 ]]
