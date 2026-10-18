#!/usr/bin/env bash
# Builds the single-file distribution artifact (ollama-cloudflare-setup.sh)
# from the Bash modules in src/. The Textual interface in tui/ola_tui.py and
# its pinned requirements are embedded into src/70-tui.sh at the build markers
# so the published artifact remains downloadable and runnable as one file.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT=${1:-"$ROOT/ollama-cloudflare-setup.sh"}
TMP=$(mktemp "${TMPDIR:-/tmp}/ola-build.XXXXXX")
trap 'rm -f "$TMP"' EXIT

modules=$(printf '%s\n' "$ROOT"/src/[0-9][0-9]-*.sh | LC_ALL=C sort)
[[ -n "$modules" ]] || { echo "No src modules found." >&2; exit 1; }

first_module=1
while IFS= read -r module; do
  [[ -f "$module" ]] || continue
  if [[ "$first_module" -eq 0 ]]; then
    printf '\n' >> "$TMP"
  fi
  first_module=0
  awk \
    -v tui_file="$ROOT/tui/ola_tui.py" \
    -v requirements_file="$ROOT/tui/requirements.txt" '
      $0 == "@@OLA_TUI_PY@@" {
        while ((getline line < tui_file) > 0) print line
        next
      }
      $0 == "@@OLA_TUI_REQUIREMENTS@@" {
        while ((getline line < requirements_file) > 0) print line
        next
      }
      { print }
    ' "$module" >> "$TMP"
done <<< "$modules"

chmod 755 "$TMP"
bash -n "$TMP"
mv "$TMP" "$OUTPUT"
artifact_sha256=$(sha256sum "$OUTPUT" | awk 'NR == 1 { print $1 }')
printf '%s  %s\n' "$artifact_sha256" "$(basename "$OUTPUT")" > "${OUTPUT}.sha256"
trap - EXIT
printf 'Built %s from %s modules.\n' "$OUTPUT" "$(printf '%s\n' "$modules" | wc -l)"
