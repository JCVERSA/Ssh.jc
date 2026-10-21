# Optional Textual terminal interface.
#
# The Python application source lives in tui/ola_tui.py in the repository.
# build.sh embeds it below, so the published single-file artifact can extract
# it next to the installed ola script. The Bash engine remains authoritative:
# the TUI only reads the local Ollama API and invokes the installed ola CLI
# for actions, preserving all existing safety checks and confirmations.

write_ola_tui_python_file(){
  local target=$1 tmp
  tmp=$(mktemp "${target}.tmp-XXXXXX") || return 1
  cat > "$tmp" <<'OLA_TUI_PY'
@@OLA_TUI_PY@@
OLA_TUI_PY
  chmod 0755 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$target"
}

write_ola_tui_requirements(){
  local target=$1 tmp
  tmp=$(mktemp "${target}.tmp-XXXXXX") || return 1
  cat > "$tmp" <<'EOF'
@@OLA_TUI_REQUIREMENTS@@
EOF
  chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$target"
}

install_ola_tui_files(){
  install -d -m 0755 "$OLA_INSTALL_DIR" || return 1
  write_ola_tui_python_file "$OLA_TUI_FILE" || return 1
  write_ola_tui_requirements "$OLA_TUI_REQUIREMENTS" || return 1
}

tui_textual_version(){
  [[ -x "$OLA_TUI_PYTHON" ]] || return 1
  "$OLA_TUI_PYTHON" -c 'import importlib.metadata; print(importlib.metadata.version("textual"))' 2>/dev/null
}

tui_environment_ready(){
  [[ -f "$OLA_TUI_FILE" && -x "$OLA_TUI_PYTHON" ]] || return 1
  [[ -n "$(tui_textual_version)" ]]
}

show_tui_status(){
  local version=""
  echo "--- Ola TUI (Textual) ---"
  echo "Application : $OLA_TUI_FILE"
  if [[ -f "$OLA_TUI_FILE" ]]; then
    echo "  fichier Python : présent"
  else
    echo "  fichier Python : absent"
  fi
  echo "Environnement : $OLA_TUI_VENV"
  if [[ -x "$OLA_TUI_PYTHON" ]]; then
    echo "  Python isolé : présent ($OLA_TUI_PYTHON)"
  else
    echo "  Python isolé : absent"
  fi
  if version=$(tui_textual_version); then
    echo "  Textual : $version (version épinglée attendue : $OLA_TUI_TEXTUAL_VERSION)"
  else
    echo "  Textual : non importable"
  fi
  if tui_environment_ready; then
    ok "TUI prête. Lancement : ola tui"
    return 0
  fi
  warn "TUI non prête. Le reste de ola fonctionne sans elle. Réparation : sudo ola tui install (ou relancer le setup)."
  return 1
}

install_tui_environment(){
  [[ $EUID -eq 0 ]] || { err "TUI installation requires root."; return 1; }
  info "Installing the optional Textual TUI in an isolated Python environment..."
  install_ola_tui_files || { err "Could not write the TUI files in $OLA_INSTALL_DIR."; return 1; }

  if ! command -v python3 >/dev/null 2>&1; then
    apt_install python3 python3-venv || { err "Could not install Python 3 for the TUI."; return 1; }
  fi
  if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
    err "Python 3.11 or newer is required for the pinned TUI dependencies; found: $(python3 --version 2>&1 || echo unknown)"
    return 1
  fi

  # A distribution venv can be left partially created without pip when the
  # python3-venv package is missing. Treat "python exists but pip does not"
  # as a broken environment, install the package, and recreate it cleanly.
  if ! { [[ -x "$OLA_TUI_PYTHON" ]] && "$OLA_TUI_PYTHON" -m pip --version >/dev/null 2>&1; }; then
    if ! python3 -m venv --clear "$OLA_TUI_VENV"; then
      warn "Python venv creation failed; installing python3-venv and retrying..."
      apt_install python3-venv || { err "Could not install python3-venv."; return 1; }
      python3 -m venv --clear "$OLA_TUI_VENV" || { err "Could not create the TUI Python environment: $OLA_TUI_VENV"; return 1; }
    fi
    if ! "$OLA_TUI_PYTHON" -m pip --version >/dev/null 2>&1; then
      if ! "$OLA_TUI_PYTHON" -m ensurepip --upgrade >/dev/null 2>&1; then
        warn "pip is missing from the Python venv; installing python3-venv and recreating it..."
        apt_install python3-venv || { err "Could not install python3-venv."; return 1; }
        python3 -m venv --clear "$OLA_TUI_VENV" || { err "Could not recreate the TUI Python environment: $OLA_TUI_VENV"; return 1; }
      fi
    fi
    "$OLA_TUI_PYTHON" -m pip --version >/dev/null 2>&1 \
      || { err "pip is unavailable in the TUI Python environment."; return 1; }
  fi

  info "Installing pinned Python packages for Textual $OLA_TUI_TEXTUAL_VERSION (network access to PyPI is required)..."
  if ! "$OLA_TUI_PYTHON" -m pip install --disable-pip-version-check --no-input --require-hashes -r "$OLA_TUI_REQUIREMENTS"; then
    err "Could not install the pinned Textual packages from PyPI."
    return 1
  fi
  if ! tui_environment_ready; then
    err "The TUI environment was created but Textual could not be imported."
    return 1
  fi
  ok "TUI installed: Textual $(tui_textual_version). Launch it with: ola tui"
}

repair_tui_environment(){
  require_root
  install_ola_command
  if ! apt_update; then
    warn "apt update failed; trying the TUI installation with the existing package lists."
  fi
  install_tui_environment || die "TUI installation failed. The rest of ola remains available; check the network/PyPI access, then retry: sudo ola tui install"
}

launch_ola_tui(){
  local cli=""
  if [[ ! -t 0 || ! -t 1 ]]; then
    die "ola tui requires an interactive terminal. Use the text commands instead (for example: ola status, ola models, ola fluid)."
  fi
  if ! tui_environment_ready; then
    err "The Textual TUI is not installed or its Python environment is incomplete."
    echo "Repair it with: sudo ola tui install" >&2
    echo "The classic interface remains available with: ola" >&2
    return 1
  fi
  if [[ -x "$OLA_COMMAND" ]]; then
    cli="$OLA_COMMAND"
  else
    cli=$(script_source_path) || die "Could not locate the ola command to give to the TUI."
  fi
  info "Starting the Ola Textual interface. Press q to quit."
  OLA_TUI_CLI="$cli" OLA_TUI_API_URL="http://127.0.0.1:11434" exec "$OLA_TUI_PYTHON" "$OLA_TUI_FILE"
}
