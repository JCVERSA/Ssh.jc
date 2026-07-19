#!/bin/bash
# ============================================================
#  fxTunnel Installer — NeoN / Bedrock UDP tunnel
#  Installe le client fxtunnel officiel (fxtun.dev) et lance
#  un tunnel UDP persistant vers le serveur Minecraft Bedrock.
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== fxTunnel Installer ===${NC}"

# ------------------------------------------------------------
# 1. Installation du client officiel fxtunnel
# ------------------------------------------------------------
if command -v fxtunnel >/dev/null 2>&1; then
    echo -e "${YELLOW}fxtunnel est déjà installé, on saute l'installation.${NC}"
else
    echo -e "${GREEN}Installation du client fxtunnel...${NC}"
    curl -fsSL https://fxtun.dev/install.sh | bash
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

read -rp "Ton token API fxtun.dev (sk_...) : " FX_TOKEN
if [ -z "$FX_TOKEN" ]; then
    echo -e "${RED}Un token est requis. Récupère-le depuis ton dashboard fxtun.dev.${NC}"
    exit 1
fi

read -rp "Adresse du serveur fxtunnel (par défaut: fxtun.dev:4443) : " FX_SERVER
FX_SERVER=${FX_SERVER:-fxtun.dev:4443}

read -rp "Ton sous-domaine déjà créé sur fxtun.dev (ex: jcversanb) : " FX_DOMAIN
if [ -z "$FX_DOMAIN" ]; then
    echo -e "${RED}Le sous-domaine est requis — il doit déjà exister dans ton dashboard.${NC}"
    exit 1
fi

read -rp "Port local à exposer en UDP (par défaut: 19132 pour Bedrock) : " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-19132}

read -rp "Nom de la session screen (par défaut: fxtunnel) : " SCREEN_NAME
SCREEN_NAME=${SCREEN_NAME:-fxtunnel}

# ------------------------------------------------------------
# 3. Vérification que screen est installé
# ------------------------------------------------------------
if ! command -v screen >/dev/null 2>&1; then
    echo -e "${YELLOW}screen n'est pas installé, installation...${NC}"
    apt update -qq && apt install -y screen
fi

# ------------------------------------------------------------
# 4. Génération du script de démarrage
# ------------------------------------------------------------
INSTALL_DIR="$HOME/fxtunnel"
mkdir -p "$INSTALL_DIR"

START_SCRIPT="$INSTALL_DIR/start-fxtunnel.sh"

cat > "$START_SCRIPT" <<EOF
#!/bin/bash
# Démarrage fxTunnel — NeonCraft Bedrock UDP
fxtunnel udp $LOCAL_PORT --domain $FX_DOMAIN --server $FX_SERVER --token $FX_TOKEN
EOF

chmod +x "$START_SCRIPT"

# ------------------------------------------------------------
# 5. Lancement dans une session screen détachée
# ------------------------------------------------------------
if screen -list | grep -q "\.${SCREEN_NAME}"; then
    echo -e "${YELLOW}Une session screen '${SCREEN_NAME}' existe déjà. Arrêt et redémarrage...${NC}"
    screen -S "$SCREEN_NAME" -X quit || true
    sleep 1
fi

screen -dmS "$SCREEN_NAME" bash -c "$START_SCRIPT"
sleep 2

if screen -list | grep -q "\.${SCREEN_NAME}"; then
    echo -e "${GREEN}✓ Tunnel fxTunnel lancé avec succès dans la session screen '${SCREEN_NAME}'.${NC}"
    echo -e "${GREEN}✓ Adresse publique attendue : ${FX_DOMAIN}.fxtun.dev${NC}"
    echo ""
    echo "Pour voir les logs en direct : screen -r $SCREEN_NAME"
    echo "Pour en sortir sans le tuer   : Ctrl+A puis D"
else
    echo -e "${RED}Le tunnel n'a pas pu démarrer. Vérifie ton token et ta connexion.${NC}"
    exit 1
fi
