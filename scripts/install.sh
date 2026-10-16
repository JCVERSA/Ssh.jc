#!/bin/sh
# ============================================================================
#  SSH.JC CONTROL CENTER — Script d'installation en une ligne
#
#  Usage (depuis n'importe quel VPS Debian/Ubuntu) :
#    curl -fsSL "https://raw.githubusercontent.com/JCVERSA/Ssh.jc/arena/e89a71aa-ssh-jc/scripts/install.sh" | sh
#
#  Ou en interactif (recommandé — permet de choisir le mot de passe) :
#    sh -c "$(curl -fsSL https://raw.githubusercontent.com/JCVERSA/Ssh.jc/arena/e89a71aa-ssh-jc/scripts/install.sh)"
#
#  Le script est idempotent : le relancer met à jour l'installation.
#  À la fin, la commande `sshjc` est disponible partout (voir: sshjc help).
#  Ne pas confondre avec `Install.sh` (à la racine) : l'installeur SSH/tunnel.
# ============================================================================
set -eu

REPO_URL="${SSHJC_REPO_URL:-https://github.com/JCVERSA/Ssh.jc}"
# Branche contenant le GUI (à repasser sur "main" après fusion dans main).
BRANCH="${SSHJC_BRANCH:-arena/e89a71aa-ssh-jc}"
INSTALL_DIR="${SSHJC_INSTALL_DIR:-}"
SKIP_SETUP="${SSHJC_SKIP_SETUP:-0}"

# ---------------------------------------------------------------------------
# Options (variables d'environnement ou arguments)
#   SSHJC_INSTALL_DIR=/chemin — dossier d'installation (défaut /opt/Ssh.jc)
#   SSHJC_BRANCH=branche      — branche git à installer
#   SSHJC_SKIP_SETUP=1        — clone + commande sshjc, sans setup complet
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      [ $# -ge 2 ] || { printf 'ERREUR: --dir nécessite un chemin\n' >&2; exit 1; }
      INSTALL_DIR="$2"; shift 2 ;;
    --branch)
      [ $# -ge 2 ] || { printf 'ERREUR: --branch nécessite un nom de branche\n' >&2; exit 1; }
      BRANCH="$2"; shift 2 ;;
    --skip-setup) SKIP_SETUP=1; shift ;;
    --help|-h)
      printf '%s\n' \
        'SSH.JC Control Center — installation rapide' \
        '' \
        'Usage: install.sh [--dir /chemin] [--branch nom] [--skip-setup]' \
        '' \
        'Variables: SSHJC_INSTALL_DIR, SSHJC_BRANCH, SSHJC_SKIP_SETUP=1'
      exit 0 ;;
    *) printf 'Option inconnue: %s (essaie --help)\n' "$1" >&2; exit 1 ;;
  esac
done

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32mOK\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31mERREUR:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
step "1/5 · Vérifications de base"
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Linux" ] || fail "Ce script cible Linux (détecté: $(uname -s))."
case "$(uname -m)" in
  x86_64|aarch64|arm64) ok "Architecture: $(uname -m)" ;;
  *) warn "Architecture non testée: $(uname -m) — on continue, sans garantie." ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  INSTALL_DIR="${INSTALL_DIR:-/opt/Ssh.jc}"
  BIN_DIR="${SSHJC_BIN_DIR:-/usr/local/bin}"
else
  INSTALL_DIR="${INSTALL_DIR:-$HOME/Ssh.jc}"
  BIN_DIR="${SSHJC_BIN_DIR:-$HOME/.local/bin}"
  warn "Mode non-root: installation dans ${INSTALL_DIR}, commande dans ${BIN_DIR}."
fi
printf '    Dossier cible : %s\n    Branche       : %s\n    Commande      : %s/sshjc\n' \
  "$INSTALL_DIR" "$BRANCH" "$BIN_DIR"

# Espace disque : dépôt + node_modules demandent ~500 Mo minimum.
INSTALL_PARENT=$(dirname "$INSTALL_DIR")
avail_mb=$(df -Pm "$INSTALL_PARENT" 2>/dev/null | awk 'NR==2{print $4}')
case "$avail_mb" in
  ''|*[!0-9]*) ;;  # df indisponible — on continue
  *)
    [ "$avail_mb" -ge 500 ] || fail "Espace disque insuffisant (${avail_mb} Mo libres sur ${INSTALL_PARENT} — il faut ~500 Mo)."
    [ "$avail_mb" -ge 1000 ] || warn "Espace disque juste (${avail_mb} Mo libres — ~1 Go recommandé)."
    ;;
esac

command -v curl >/dev/null 2>&1 || fail "curl est introuvable — installe-le d'abord (apt install curl)."

# ---------------------------------------------------------------------------
step "2/5 · git"
# ---------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || \
      warn "apt update a échoué — on tente quand même."
    DEBIAN_FRONTEND=noninteractive apt-get install -y git >/dev/null 2>&1 || \
      fail "Installation de git impossible (essaie: apt install git)."
  else
    fail "git est introuvable — installe-le (apt install git) puis relance."
  fi
fi
ok "git $(git --version 2>/dev/null | awk '{print $3}')"

# ---------------------------------------------------------------------------
step "3/5 · Récupération du code"
# ---------------------------------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
  CUR_REMOTE=$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null || true)
  case "$CUR_REMOTE" in
    "$REPO_URL"|"$REPO_URL.git"|git@github.com:JCVERSA/Ssh.jc|git@github.com:JCVERSA/Ssh.jc.git)
      : # même dépôt
      ;;
    '')
      git -C "$INSTALL_DIR" remote add origin "$REPO_URL.git" \
        || fail "Impossible d'ajouter l'origin au dépôt existant."
      ;;
    *)
      warn "Dépôt existant lié à $CUR_REMOTE — re-liaison vers $REPO_URL…"
      git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL.git" \
        || fail "Impossible de changer l'origin."
      ;;
  esac

  git -C "$INSTALL_DIR" fetch origin "$BRANCH" \
    || fail "Fetch impossible depuis $REPO_URL (branche $BRANCH)."

  if [ -n "$(git -C "$INSTALL_DIR" status --porcelain 2>/dev/null)" ]; then
    warn "Modifications locales détectées — code actuel conservé, AUCUN écrasement."
    warn "Range-les (git stash / commit) puis relance pour aligner sur origin/$BRANCH."
  else
    git -C "$INSTALL_DIR" checkout -B "$BRANCH" "origin/$BRANCH" >/dev/null 2>&1 \
      || fail "Alignement sur origin/$BRANCH impossible."
    git -C "$INSTALL_DIR" config pull.ff only
    ok "Dépôt mis à jour ($(git -C "$INSTALL_DIR" log -1 --format='%h'))."
  fi
else
  mkdir -p "$INSTALL_DIR"
  [ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ] || \
    fail "$INSTALL_DIR n'est pas vide et n'est pas un dépôt git."
  # Clone superficiel : l'historique complet ne sert pas à l'exécution.
  git clone --depth 1 --single-branch -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR" \
    || fail "Clonage impossible (réseau ?)."
  git -C "$INSTALL_DIR" config pull.ff only
  ok "Dépôt cloné ($(git -C "$INSTALL_DIR" log -1 --format='%h'))."
fi

[ -f "$INSTALL_DIR/Install.sh" ] || fail "Install.sh absent du dépôt cloné — branche incorrecte ?"
[ -f "$INSTALL_DIR/manage.sh" ] || fail "manage.sh absent du dépôt cloné — branche incorrecte ?"
[ -d "$INSTALL_DIR/gui" ] || fail "Dossier gui/ absent du dépôt cloné — branche incorrecte ?"

# ---------------------------------------------------------------------------
step "4/5 · Commande 'sshjc'"
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
chmod +x "$INSTALL_DIR/manage.sh"
ln -sf "$INSTALL_DIR/manage.sh" "$BIN_DIR/sshjc" \
  || fail "Impossible de créer le lien $BIN_DIR/sshjc."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    if [ "$(id -u)" -ne 0 ]; then
      for prof in "$HOME/.profile" "$HOME/.bashrc"; do
        if [ -f "$prof" ] && ! grep -q "PATH=\"$BIN_DIR" "$prof" 2>/dev/null; then
          printf "\n# Added by SSH.JC installer\nPATH=\"%s:\$PATH\"\n" "$BIN_DIR" >> "$prof" && break
        fi
      done
      PATH="$BIN_DIR:$PATH"
      warn "$BIN_DIR ajouté au PATH du profil (recharge ta session ou: source ~/.profile)."
    fi
    ;;
esac
ok "Commande \`sshjc\` installée → $BIN_DIR/sshjc"

# ---------------------------------------------------------------------------
step "5/5 · Setup (dépendances, .env, mot de passe, build, service)"
# ---------------------------------------------------------------------------
if [ "$SKIP_SETUP" = "1" ]; then
  warn "SSHJC_SKIP_SETUP=1 / --skip-setup — setup sauté. Lance ensuite: sshjc setup"
else
  bash "$INSTALL_DIR/manage.sh" setup \
    || fail "Échec de setup. Consulte les messages ci-dessus, puis: sshjc setup"
  ok "Setup terminé (dépendances + build + service si systemd disponible)."
fi

# Port configuré (pour les instructions d'accès).
GUI_PORT_VALUE=$(sed -n 's/^[[:space:]]*GUI_PORT[[:space:]]*=[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}[[:space:]]*$/\1/p' \
  "$INSTALL_DIR/gui/.env" 2>/dev/null | tail -n 1)
case "$GUI_PORT_VALUE" in ''|*[!0-9]*) GUI_PORT_VALUE=3000 ;; esac

printf '\n'
printf '\033[1;36m=====================================================\033[0m\n'
printf '\033[1m  SSH.JC CONTROL CENTER installé avec succès 🎉\033[0m\n'
printf '\033[1;36m=====================================================\033[0m\n'
printf '  Dossier      : %s\n' "$INSTALL_DIR"
printf '  Version      : %s (%s)\n' "$(git -C "$INSTALL_DIR" log -1 --format='%h' 2>/dev/null || echo '?')" "$BRANCH"
printf '  Commande     : sshjc  (essaie: sshjc help)\n'
printf '\n'
printf '  Prochaines étapes :\n'
printf '   1. \033[1msshjc status\033[0m     — vérifie que la console répond\n'
printf '   2. \033[1mssh -L %s:127.0.0.1:%s user@TON-VPS\033[0m  — depuis ton PC\n' "$GUI_PORT_VALUE" "$GUI_PORT_VALUE"
printf '   3. Ouvre \033[1mhttp://localhost:%s\033[0m et connecte-toi\n' "$GUI_PORT_VALUE"
printf '\n'
printf '  Mot de passe oublié/non défini : \033[1msshjc password\033[0m\n'
printf '  Mises à jour futures           : \033[1msshjc update\033[0m\n'
printf '\n'
