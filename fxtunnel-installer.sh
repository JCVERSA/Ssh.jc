#!/bin/bash
# ============================================================
#  fxTunnel Installer — NeoN / Bedrock UDP tunnel
#  Installe le client fxtunnel officiel (fxtun.dev) et lance
#  un tunnel UDP persistant vers le serveur Minecraft Bedrock.
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== fxTunnel Installer ===${NC}"

# ------------------------------------------------------------
# Validation des saisies (F-03) : mêmes règles que Install.sh
# ------------------------------------------------------------
is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Un seul label DNS (ex: jcversanb), lettres/chiffres/tirets.
is_valid_label() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

# host:port (ex: fxtun.dev:4443)
is_valid_server() {
    local host="${1%:*}"
    local port="${1##*:}"
    [[ "$1" == *:* && "$host" =~ ^[A-Za-z0-9.-]+$ ]] && is_valid_port "$port"
}

is_valid_screen_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

# ------------------------------------------------------------
# 1. Installation du client officiel fxtunnel
# ------------------------------------------------------------
if command -v fxtunnel >/dev/null 2>&1; then
    echo -e "${YELLOW}fxtunnel est déjà installé, on saute l'installation.${NC}"
else
    echo -e "${GREEN}Installation du client fxtunnel...${NC}"
    # F-01 : ne jamais exécuter `curl | bash`. On télécharge le script
    # dans un fichier temporaire, on avertit qu'aucun checksum publié
    # ne permet de le vérifier, et on demande confirmation explicite
    # avant de l'exécuter (même approche que Install.sh).
    FX_INSTALLER_TMP=$(mktemp "/tmp/fxtunnel-install-XXXXXX.sh")
    if ! curl -fsSL "https://fxtun.dev/install.sh" -o "$FX_INSTALLER_TMP"; then
        echo -e "${RED}Erreur : téléchargement de l'installeur fxtunnel impossible.${NC}"
        rm -f "$FX_INSTALLER_TMP"
        exit 1
    fi
    echo -e "${YELLOW}Aucun checksum publié n'existe pour le script install.sh lui-même ; il va s'exécuter avec tes privilèges actuels.${NC}"
    echo -e "${YELLOW}Tu peux le relire ici : $FX_INSTALLER_TMP${NC}"
    read -rp "Continuer et exécuter cet installeur non vérifié ? [y/N] : " FX_CONFIRM
    if [[ ! "$FX_CONFIRM" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo -e "${RED}Installation annulée (installeur non vérifié).${NC}"
        rm -f "$FX_INSTALLER_TMP"
        exit 1
    fi
    bash "$FX_INSTALLER_TMP"
    rm -f "$FX_INSTALLER_TMP"
fi

# L'installeur officiel place le binaire dans ~/.local/bin mais ne met à
# jour que les FUTURS shells (.bashrc/.profile) : ce shell-ci ne le voit
# pas, ce qui faisait échouer la vérification ci-dessous même après une
# installation réussie. On ajoute nous-mêmes le dossier au PATH.
if ! command -v fxtunnel >/dev/null 2>&1; then
    for fx_dir in "$HOME/.local/bin" "/usr/local/bin"; do
        if [[ -x "${fx_dir}/fxtunnel" ]]; then
            export PATH="${fx_dir}:$PATH"
            echo -e "${GREEN}${fx_dir} ajouté au PATH pour cette session (fxtunnel trouvé).${NC}"
            break
        fi
    done
fi

if ! command -v fxtunnel >/dev/null 2>&1; then
    echo -e "${RED}Erreur : fxtunnel n'a pas été trouvé après installation.${NC}"
    echo -e "${RED}Vérifie que /usr/local/bin est dans ton PATH.${NC}"
    exit 1
fi

# ------------------------------------------------------------
# 2. Collecte des infos utilisateur
# ------------------------------------------------------------
echo ""
echo -e "${GREEN}--- Configuration du tunnel ---${NC}"

# F-02 : -s = saisie masquée, le token ne s'affiche pas à l'écran.
read -rsp "Ton token API fxtun.dev (sk_...) : " FX_TOKEN
echo ""
if [ -z "$FX_TOKEN" ]; then
    echo -e "${RED}Un token est requis. Récupère-le depuis ton dashboard fxtun.dev.${NC}"
    exit 1
fi

while true; do
    read -rp "Adresse du serveur fxtunnel (par défaut: fxtun.dev:4443) : " FX_SERVER
    FX_SERVER=${FX_SERVER:-fxtun.dev:4443}
    if is_valid_server "$FX_SERVER"; then
        break
    fi
    echo -e "${RED}Adresse invalide : '$FX_SERVER'. Format attendu : hôte:port (ex: fxtun.dev:4443).${NC}"
done

while true; do
    read -rp "Ton sous-domaine déjà créé sur fxtun.dev (ex: jcversanb) : " FX_DOMAIN
    if [ -z "$FX_DOMAIN" ]; then
        echo -e "${RED}Le sous-domaine est requis — il doit déjà exister dans ton dashboard.${NC}"
        exit 1
    fi
    if is_valid_label "$FX_DOMAIN"; then
        break
    fi
    echo -e "${RED}Sous-domaine invalide : '$FX_DOMAIN'. Lettres, chiffres et tirets uniquement (un seul label).${NC}"
done

while true; do
    read -rp "Port local à exposer en UDP (par défaut: 19132 pour Bedrock) : " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-19132}
    if is_valid_port "$LOCAL_PORT"; then
        break
    fi
    echo -e "${RED}Port invalide : '$LOCAL_PORT'. Entre un nombre entre 1 et 65535.${NC}"
done

while true; do
    read -rp "Nom de la session screen (par défaut: fxtunnel) : " SCREEN_NAME
    SCREEN_NAME=${SCREEN_NAME:-fxtunnel}
    if is_valid_screen_name "$SCREEN_NAME"; then
        break
    fi
    echo -e "${RED}Nom de session invalide : '$SCREEN_NAME'. Lettres, chiffres, '.', '_' et '-' uniquement.${NC}"
done

# ------------------------------------------------------------
# 3. Vérification que screen est installé
# ------------------------------------------------------------
if ! command -v screen >/dev/null 2>&1; then
    echo -e "${YELLOW}screen n'est pas installé, installation...${NC}"
    # F-10 : apt exige root ou sudo ; échouer clairement sinon.
    SUDO_CMD=()
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO_CMD=(sudo)
        else
            echo -e "${RED}Erreur : screen est absent et ni root ni sudo ne sont disponibles. Installe-le manuellement : apt install -y screen${NC}"
            exit 1
        fi
    fi
    "${SUDO_CMD[@]}" apt update -qq && "${SUDO_CMD[@]}" apt install -y screen
fi

# ------------------------------------------------------------
# 4. Génération du script de démarrage
# ------------------------------------------------------------
INSTALL_DIR="$HOME/fxtunnel"
# F-02 : umask restrictif + dossier 700 + script 700. Le token ne doit
# être lisible que par son propriétaire.
umask 077
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"

START_SCRIPT="$INSTALL_DIR/start-fxtunnel.sh"

# F-03 : valeurs échappées avec %q, jamais interpolées brutes dans du
# code shell généré (un token/domaine avec espaces ou métacaractères
# ne peut ni casser le script ni y injecter une commande).
Q_PORT=$(printf '%q' "$LOCAL_PORT")
Q_DOMAIN=$(printf '%q' "$FX_DOMAIN")
Q_SERVER=$(printf '%q' "$FX_SERVER")
Q_TOKEN=$(printf '%q' "$FX_TOKEN")

cat > "$START_SCRIPT" <<EOF
#!/bin/bash
# Démarrage fxTunnel — NeonCraft Bedrock UDP
# Le token passe par l'environnement du client (FXTUNNEL_TOKEN, lu
# nativement par fxtunnel) : il n'apparaît jamais dans 'ps aux'.
FXTUNNEL_TOKEN=$Q_TOKEN fxtunnel udp $Q_PORT --domain $Q_DOMAIN --server $Q_SERVER
EOF

chmod 700 "$START_SCRIPT"

# ------------------------------------------------------------
# 5. Lancement dans une session screen détachée
# ------------------------------------------------------------
if screen -list | grep -qF ".${SCREEN_NAME}"; then
    echo -e "${YELLOW}Une session screen '${SCREEN_NAME}' existe déjà. Arrêt et redémarrage...${NC}"
    screen -S "$SCREEN_NAME" -X quit || true
    sleep 1
fi

screen -dmS "$SCREEN_NAME" bash -c "$START_SCRIPT"
sleep 2

if screen -list | grep -qF ".${SCREEN_NAME}"; then
    echo -e "${GREEN}✓ Tunnel fxTunnel lancé avec succès dans la session screen '${SCREEN_NAME}'.${NC}"
    echo -e "${GREEN}✓ Adresse publique attendue : ${FX_DOMAIN}.fxtun.dev${NC}"
    echo ""
    echo "Pour voir les logs en direct : screen -r $SCREEN_NAME"
    echo "Pour en sortir sans le tuer   : Ctrl+A puis D"
else
    echo -e "${RED}Le tunnel n'a pas pu démarrer. Vérifie ton token et ta connexion.${NC}"
    exit 1
fi
