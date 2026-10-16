#!/usr/bin/env bash
# ============================================================================
#  SSH.JC CONTROL CENTER — Script de gestion VPS (console web pour Install.sh)
#  Dépôt   : https://github.com/JCVERSA/Ssh.jc
#  Usage   : ./manage.sh <commande>   (voir: ./manage.sh help)
#
#  Commandes : clone | setup | start | stop | restart | status | update
#              password | env [list|set|get|unset] | logs | doctor | version
#
#  Installation rapide sur un VPS vierge :
#    curl -fsSL https://raw.githubusercontent.com/JCVERSA/Ssh.jc/arena/e89a71aa-ssh-jc/manage.sh -o manage.sh
#    bash manage.sh clone        # clone le dépôt puis lance setup
# ============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/JCVERSA/Ssh.jc"
# Branche contenant le GUI (à repasser sur "main" après fusion).
BRANCH="${SSHJC_BRANCH:-arena/e89a71aa-ssh-jc}"
SERVICE="sshjc-control-center"

# Résout l'emplacement réel du script À TRAVERS les liens symboliques.
SSHJC_SRC="${BASH_SOURCE[0]}"
while [ -L "${SSHJC_SRC}" ]; do
  SSHJC_DIR="$(cd "$(dirname "${SSHJC_SRC}")" && pwd)"
  SSHJC_SRC="$(readlink "${SSHJC_SRC}")"
  case "${SSHJC_SRC}" in /*) ;; *) SSHJC_SRC="${SSHJC_DIR}/${SSHJC_SRC}" ;; esac
done
APP_DIR="$(cd "$(dirname "${SSHJC_SRC}")" && pwd)"   # racine du dépôt Ssh.jc
GUI_DIR="${APP_DIR}/gui"
ENV_FILE="${GUI_DIR}/.env"
LOG_FILE="${LOG_FILE:-${GUI_DIR}/console.log}"
PID_PATTERN="${GUI_DIR}/node_modules/.bin/tsx server[.]ts"

# ---------------------------------------------------------------------------
# Couleurs (désactivées hors TTY, ex: cron)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_YELLOW=$'\033[1;33m'
  C_CYAN=$'\033[1;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi
ok()   { echo "${C_GREEN}✔${C_RESET} $*"; }
ko()   { echo "${C_RED}✘${C_RESET} $*" >&2; }
warn() { echo "${C_YELLOW}⚠${C_RESET} $*"; }
info() { echo "${C_CYAN}ℹ${C_RESET} $*"; }
hdr()  { echo; echo "${C_BOLD}${C_CYAN}═══ $* ═══${C_RESET}"; }
die()  { ko "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
env_value() { # $1 = clé → valeur brute ou vide
  [ -f "${ENV_FILE}" ] || return 0
  grep -E "^${1}=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}

env_set() { # $1 = clé, $2 = valeur (crée .env si besoin, permissions 600)
  local key="$1" value="$2"
  mkdir -p "${GUI_DIR}"
  if [ -f "${ENV_FILE}" ] && grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
  chmod 600 "${ENV_FILE}" 2>/dev/null || true
}

gui_port() {
  local p; p="$(env_value GUI_PORT)"
  case "${p}" in ''|*[!0-9]*) echo 3000 ;; *) echo "${p}" ;; esac
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 \
    && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] \
    && [ -f "/etc/systemd/system/${SERVICE}.service" ]
}

gui_pids() { pgrep -f "${PID_PATTERN}" 2>/dev/null | grep -v "^$$\$" || true; }

is_running() {
  if systemd_available; then
    systemctl is-active --quiet "${SERVICE}" 2>/dev/null
  else
    [ -n "$(gui_pids)" ]
  fi
}

wait_health() { # attend /api/health (max ~30 s)
  local port="$1"
  command -v curl >/dev/null 2>&1 || return 1
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

require_gui() {
  [ -d "${GUI_DIR}" ] || die "Dossier gui/ introuvable dans ${APP_DIR}. Utilise: ./manage.sh clone"
  [ -f "${APP_DIR}/Install.sh" ] || die "Install.sh introuvable à la racine (${APP_DIR})."
}

check_node() {
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    [ "${major}" -ge 20 ] 2>/dev/null && { ok "Node.js $(node --version)"; return 0; }
    warn "Node.js $(node --version) trop ancien (≥ 20 requis)."
  fi
  # Installation rapide via NodeSource si root + apt disponibles.
  if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    info "Installation de Node.js 20 via NodeSource…"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1 \
      && apt-get install -y nodejs >/dev/null 2>&1 \
      && { ok "Node.js $(node --version) installé"; return 0; }
  fi
  die "Node.js ≥ 20 introuvable — installe-le: https://nodejs.org (ou lance ce script en root sur Debian/Ubuntu)."
}

set_password_hash() { # $1 = mot de passe en clair → écrit GUI_PASSWORD_HASH dans .env
  local hash
  hash="$(cd "${GUI_DIR}" && node scripts/set-password.mjs "$1" 2>/dev/null)" \
    || die "Échec de génération du hash (node scripts/set-password.mjs)."
  env_set GUI_PASSWORD_HASH "${hash#GUI_PASSWORD_HASH=}"
  # Un hash explicite prime ; on retire un éventuel mot de passe en clair.
  if [ -f "${ENV_FILE}" ]; then
    sed -i '/^GUI_PASSWORD=/d' "${ENV_FILE}"
  fi
  ok "Mot de passe de la console enregistré (hash scrypt dans gui/.env)."
}

# ---------------------------------------------------------------------------
# Commandes
# ---------------------------------------------------------------------------
cmd_clone() {
  local dir="${1:-/opt/Ssh.jc}"
  [ -e "${dir}" ] && [ -n "$(ls -A "${dir}" 2>/dev/null)" ] \
    && die "Le dossier ${dir} existe déjà et n'est pas vide."
  command -v git >/dev/null 2>&1 || die "git est introuvable (apt install git)."
  hdr "Clonage de ${REPO_URL} (branche ${BRANCH}) → ${dir}"
  mkdir -p "$(dirname "${dir}")"
  git clone -b "${BRANCH}" "${REPO_URL}" "${dir}" || die "Clonage échoué."
  ok "Dépôt cloné."
  ( cd "${dir}" && git config pull.ff only )
  exec bash "${dir}/manage.sh" setup
}

cmd_setup() {
  require_gui
  hdr "Prérequis"
  command -v git >/dev/null 2>&1 || die "git est introuvable (apt install git)."
  check_node
  command -v npm >/dev/null 2>&1 || die "npm introuvable — réinstalle Node.js."

  hdr "Dépendances npm"
  ( cd "${GUI_DIR}" && npm ci --no-audit --no-fund 2>&1 | tail -n 5 | sed 's/^/    /' ) \
    || ( cd "${GUI_DIR}" && npm install --no-audit --no-fund 2>&1 | tail -n 5 | sed 's/^/    /' ) \
    || die "npm ci/install a échoué."

  hdr "Fichier .env"
  if [ ! -f "${ENV_FILE}" ]; then
    cp "${GUI_DIR}/.env.example" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    info ".env créé depuis .env.example."
  else
    ok ".env déjà présent."
  fi

  hdr "Mot de passe de la console"
  local pw_plain; pw_plain="$(env_value GUI_PASSWORD)"
  if [ -n "$(env_value GUI_PASSWORD_HASH)" ] || { [ -n "${pw_plain}" ] && [ "${pw_plain}" != "change-me" ]; }; then
    ok "Un mot de passe est déjà configuré (change-le avec: ./manage.sh password)."
  elif [ -t 0 ]; then
    local pw1="" pw2=""
    read -r -s -p "Choisis le mot de passe de la console : " pw1; echo
    read -r -s -p "Confirme le mot de passe : " pw2; echo
    [ -n "${pw1}" ] || die "Mot de passe vide — relance ./manage.sh password plus tard."
    [ "${pw1}" = "${pw2}" ] || die "Les mots de passe ne correspondent pas."
    set_password_hash "${pw1}"
  else
    warn "Pas de TTY (ou mot de passe resté à 'change-me') : définis-en un vrai"
    warn "avec ./manage.sh password — sinon un mot de passe aléatoire sera"
    warn "affiché une fois dans les logs au premier démarrage."
  fi

  hdr "Build du frontend"
  ( cd "${GUI_DIR}" && npm run build 2>&1 | tail -n 3 | sed 's/^/    /' ) || die "Build échoué."

  hdr "Service systemd"
  if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
    local unit="/etc/systemd/system/${SERVICE}.service"
    if [ "$(id -u)" -eq 0 ]; then
      cat > "${unit}" <<UNIT
[Unit]
Description=SSH.JC Control Center (web console for Install.sh)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${GUI_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/npm run start
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload
      systemctl enable --now "${SERVICE}" 2>&1 | tail -n 2 | sed 's/^/    /' || true
      ok "Service ${SERVICE} installé et démarré."
    else
      warn "systemd détecté mais tu n'es pas root : service non installé."
      warn "Relance en root, ou démarre manuellement : ./manage.sh start"
    fi
  else
    warn "systemd non détecté (conteneur ?) — démarrage manuel : ./manage.sh start"
  fi

  local port; port="$(gui_port)"
  if wait_health "${port}"; then
    ok "Console opérationnelle : http://127.0.0.1:${port} (santé OK)"
  else
    info "Vérifie le démarrage : ./manage.sh status puis ./manage.sh logs"
  fi
  echo
  info "Accès depuis ton PC (tunnel SSH, recommandé) :"
  info "  ssh -L ${port}:127.0.0.1:${port} $(whoami)@$(hostname -f 2>/dev/null || echo TON-VPS)"
  info "  puis ouvre http://localhost:${port}"
}

cmd_start() {
  require_gui
  if systemd_available; then
    systemctl start "${SERVICE}" && ok "Service démarré."
  else
    if [ -n "$(gui_pids)" ]; then warn "La console tourne déjà (PID $(gui_pids | tr '\n' ' '))."; return 0; fi
    [ -d "${GUI_DIR}/node_modules" ] || die "Dépendances absentes — lance d'abord: ./manage.sh setup"
    [ -f "${GUI_DIR}/dist/index.html" ] || ( cd "${GUI_DIR}" && npm run build >/dev/null 2>&1 ) \
      || die "Build absent et impossible — lance: ./manage.sh setup"
    info "Démarrage en arrière-plan (logs: ${LOG_FILE})…"
    # Detach stdio completely: otherwise the intermediate shell keeps the
    # caller's stdout pipe open and `sshjc start | ...` would hang forever.
    (
      cd "${GUI_DIR}" || exit 1
      exec nohup npm run start
    ) >> "${LOG_FILE}" 2>&1 < /dev/null &
    sleep 2
  fi
  local port; port="$(gui_port)"
  if wait_health "${port}"; then ok "Console joignable sur http://127.0.0.1:${port}"; \
  else warn "Pas de réponse santé sur le port ${port} — ./manage.sh logs"; fi
}

cmd_stop() {
  if systemd_available; then
    systemctl stop "${SERVICE}" && ok "Service arrêté."
  else
    local pids; pids="$(gui_pids)"
    [ -n "${pids}" ] || { info "La console n'est pas en cours d'exécution."; return 0; }
    echo "${pids}" | xargs -r kill 2>/dev/null || true
    sleep 1
    pids="$(gui_pids)"
    [ -n "${pids}" ] && echo "${pids}" | xargs -r kill -9 2>/dev/null || true
    ok "Console arrêtée."
  fi
}

cmd_restart() { cmd_stop; sleep 1; cmd_start; }

cmd_status() {
  hdr "SSH.JC Control Center"
  local port; port="$(gui_port)"
  if systemd_available; then
    systemctl --no-pager --lines=0 status "${SERVICE}" 2>/dev/null | head -n 8 | sed 's/^/    /' || true
  fi
  if is_running; then
    ok "En cours d'exécution (port ${port})."
  else
    ko "Arrêté."
  fi
  if curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
    ok "Santé API : OK (http://127.0.0.1:${port}/api/health)"
  else
    warn "Santé API : pas de réponse sur le port ${port}."
  fi
  if [ -f "${ENV_FILE}" ]; then
    if [ -n "$(env_value GUI_PASSWORD_HASH)" ]; then
      ok ".env présent (mot de passe: hash défini)"
    else
      ok ".env présent (mot de passe: voir .env)"
    fi
  else
    warn ".env absent — ./manage.sh setup"
  fi
  info "Accès distant (tunnel SSH) : ssh -L ${port}:127.0.0.1:${port} $(whoami)@$(hostname -f 2>/dev/null || echo TON-VPS)"
}

cmd_update() {
  require_gui
  [ -d "${APP_DIR}/.git" ] || die "Pas un dépôt git (${APP_DIR})."
  hdr "Mise à jour du code"
  git -C "${APP_DIR}" pull --ff-only || die "git pull a échoué (modifications locales ?)."
  ok "Code à jour ($(git -C "${APP_DIR}" rev-parse --short HEAD))."
  hdr "Dépendances + build"
  ( cd "${GUI_DIR}" && npm ci --no-audit --no-fund 2>&1 | tail -n 3 | sed 's/^/    /' ) || die "npm ci a échoué."
  ( cd "${GUI_DIR}" && npm run build 2>&1 | tail -n 3 | sed 's/^/    /' ) || die "Build échoué."
  hdr "Redémarrage"
  if is_running; then cmd_restart; else info "Console arrêtée — démarre avec: ./manage.sh start"; fi
}

cmd_password() {
  require_gui
  local pw="${SSHJC_NEW_PASSWORD:-}"
  if [ -z "${pw}" ]; then
    [ -t 0 ] || die "Pas de TTY : définis SSHJC_NEW_PASSWORD='...' ./manage.sh password"
    local pw2=""
    read -r -s -p "Nouveau mot de passe de la console : " pw; echo
    read -r -s -p "Confirme le mot de passe : " pw2; echo
    [ -n "${pw}" ] || die "Mot de passe vide."
    [ "${pw}" = "${pw2}" ] || die "Les mots de passe ne correspondent pas."
  fi
  set_password_hash "${pw}"
  if is_running; then
    info "Redémarre pour appliquer : ./manage.sh restart"
  fi
}

cmd_env() {
  local action="${1:-list}" key="${2:-}" value="${3:-}"
  case "${action}" in
    list)
      hdr "Configuration (gui/.env)"
      if [ ! -f "${ENV_FILE}" ]; then warn ".env absent — ./manage.sh setup"; return 0; fi
      while IFS= read -r line; do
        case "${line}" in
          GUI_PASSWORD*|*HASH*) echo "  ${line%%=*} = ***(masqué)" ;;
          ''|'#'*) ;;
          *) echo "  ${line}" ;;
        esac
      done < "${ENV_FILE}"
      ;;
    get) [ -n "${key}" ] || die "Usage: ./manage.sh env get CLE"; env_value "${key}" ;;
    set)
      [ -n "${key}" ] && [ -n "${value}" ] || die "Usage: ./manage.sh env set CLE VALEUR"
      case "${key}" in GUI_PASSWORD*) die "Utilise ./manage.sh password (hash scrypt, jamais en clair)." ;; esac
      env_set "${key}" "${value}"; ok "${key} mis à jour. Redémarre : ./manage.sh restart"
      ;;
    unset)
      [ -n "${key}" ] || die "Usage: ./manage.sh env unset CLE"
      [ -f "${ENV_FILE}" ] && sed -i "/^${key}=/d" "${ENV_FILE}"
      ok "${key} retiré."
      ;;
    *) die "Usage: ./manage.sh env [list|get|set|unset]" ;;
  esac
}

cmd_logs() {
  if systemd_available; then
    journalctl -u "${SERVICE}" -n 100 --no-pager 2>/dev/null | tail -n 100
  elif [ -f "${LOG_FILE}" ]; then
    tail -n 100 "${LOG_FILE}"
  else
    warn "Aucun log trouvé (${LOG_FILE})."
  fi
}

cmd_doctor() {
  hdr "Diagnostic"
  if command -v git >/dev/null 2>&1; then ok "git $(git --version | awk '{print $3}')"; else ko "git introuvable"; fi
  if command -v node >/dev/null 2>&1; then ok "Node.js $(node --version)"; else ko "Node.js introuvable (≥ 20 requis)"; fi
  if command -v npm >/dev/null 2>&1; then ok "npm $(npm --version)"; else ko "npm introuvable"; fi
  if [ -f "${APP_DIR}/Install.sh" ]; then ok "Install.sh présent (${APP_DIR}/Install.sh)"; else ko "Install.sh absent"; fi
  if [ -d "${GUI_DIR}/node_modules" ]; then ok "node_modules présent"; else warn "node_modules absent — ./manage.sh setup"; fi
  if [ -f "${GUI_DIR}/dist/index.html" ]; then ok "Build présent (dist/)"; else warn "Build absent — effectue ./manage.sh setup"; fi
  if [ -f "${ENV_FILE}" ]; then ok ".env présent"; else warn ".env absent — ./manage.sh setup"; fi
  if [ -n "$(env_value GUI_PASSWORD_HASH)" ] || [ -n "$(env_value GUI_PASSWORD)" ]; then
    ok "Mot de passe console configuré"
  else
    warn "Aucun mot de passe — un mot de passe aléatoire sera affiché au démarrage (logs)."
  fi
  local port; port="$(gui_port)"
  if curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
    ok "Console en ligne sur le port ${port}"
  else
    info "Console hors ligne (port ${port}) — ./manage.sh start"
  fi
}

cmd_version() {
  local rev="?"
  [ -d "${APP_DIR}/.git" ] && rev="$(git -C "${APP_DIR}" rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "SSH.JC Control Center — dépôt ${rev} (branche $(git -C "${APP_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'))"
  command -v node >/dev/null 2>&1 && echo "Node.js $(node --version)"
}

cmd_help() {
  cat <<EOF
SSH.JC Control Center — gestion du GUI (console web pour Install.sh)

Usage : ./manage.sh <commande>

  clone [dossier]   Clone le dépôt (défaut /opt/Ssh.jc) puis lance setup
  setup             Installe tout : Node, dépendances, .env, mot de passe,
                    build, service systemd (si disponible)
  start             Démarre la console (systemd si installé, sinon arrière-plan)
  stop              Arrête la console
  restart           Redémarre la console
  status            État du service + santé de l'API
  update            git pull + npm ci + build + redémarrage
  password          Définit/change le mot de passe de la console
  env [list|get|set|unset]   Affiche/modifie gui/.env (secrets masqués)
  logs              100 dernières lignes (journal systemd ou console.log)
  doctor            Vérifie l'installation (Node, build, .env, santé…)
  version           Révision du dépôt + version de Node
  help              Cette aide

Installation rapide (VPS vierge) :
  curl -fsSL https://raw.githubusercontent.com/JCVERSA/Ssh.jc/${BRANCH}/manage.sh -o manage.sh
  bash manage.sh clone
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-help}" in
  clone)    shift; cmd_clone "$@" ;;
  setup)    cmd_setup ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  status)   cmd_status ;;
  update)   cmd_update ;;
  password) cmd_password ;;
  env)      shift; cmd_env "$@" ;;
  logs)     cmd_logs ;;
  doctor)   cmd_doctor ;;
  version)  cmd_version ;;
  help|-h|--help) cmd_help ;;
  *) ko "Commande inconnue: $1"; cmd_help; exit 1 ;;
esac
