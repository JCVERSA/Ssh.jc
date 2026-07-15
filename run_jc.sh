#!/usr/bin/env bash
#
# setup-ssh-tunnel.sh
# Interactive installer: OpenSSH server + Cloudflare Tunnel (SSH access via a domain)
#
# Compatible with Ubuntu/Debian. Requires root access (sudo) and a domain
# already added to a Cloudflare account.
#
# Usage:
#   chmod +x setup-ssh-tunnel.sh
#   ./setup-ssh-tunnel.sh
#

set -uo pipefail

# ---------------------------------------------------------------------------
# Colors and display helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
title()   { echo -e "\n${BOLD}== $1 ==${NC}\n"; }

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │   SSH + Cloudflare Tunnel Setup              │"
    echo "  │   for Jcversa                                │"
    echo "  └─────────────────────────────────────────────┘"
    echo -e "${NC}"
}

ask() {
    # ask "question" "default_value"
    local question="$1"
    local default="${2:-}"
    local answer
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${BOLD}${question}${NC} [${default}]: ")" answer
        echo "${answer:-$default}"
    else
        read -rp "$(echo -e "${BOLD}${question}${NC}: ")" answer
        echo "$answer"
    fi
}

confirm() {
    # confirm "question" -> returns 0 (yes) or 1 (no)
    local question="$1"
    local answer
    read -rp "$(echo -e "${BOLD}${question}${NC} [y/N]: ")" answer
    [[ "$answer" =~ ^([yY][eE][sS]|[yY])$ ]]
}

require_root_tools() {
    if ! command -v sudo &>/dev/null; then
        error "sudo is not available on this system. The script must be run as root or with sudo installed."
        exit 1
    fi
}

LOG_FILE="/tmp/setup-ssh-tunnel-$(date +%Y%m%d-%H%M%S).log"

banner
info "Command details will also be logged to: $LOG_FILE"

# ---------------------------------------------------------------------------
# Step 0: Pre-flight checks
# ---------------------------------------------------------------------------
title "Pre-flight checks"

require_root_tools

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    info "Detected system: $PRETTY_NAME"
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
        warn "This script targets Ubuntu/Debian. Your system ($PRETTY_NAME) might not be compatible."
        confirm "Continue anyway?" || exit 1
    fi
else
    warn "Could not detect the distribution (/etc/os-release missing)."
    confirm "Continue anyway?" || exit 1
fi

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
title "What do you want to do?"

echo "  1) Full setup (SSH + cloudflared + tunnel + DNS route)"
echo "  2) Install OpenSSH server only"
echo "  3) Install cloudflared only (no tunnel configuration)"
echo "  4) Create / configure a Cloudflare tunnel (cloudflared already installed)"
echo "  5) Run an already configured tunnel"
echo "  6) Quit"
echo

MODE=$(ask "Choice (1-6)" "1")

case "$MODE" in
    1) DO_SSH=1; DO_INSTALL_CF=1; DO_CREATE_TUNNEL=1; DO_ROUTE_DNS=1; DO_RUN=1 ;;
    2) DO_SSH=1; DO_INSTALL_CF=0; DO_CREATE_TUNNEL=0; DO_ROUTE_DNS=0; DO_RUN=0 ;;
    3) DO_SSH=0; DO_INSTALL_CF=1; DO_CREATE_TUNNEL=0; DO_ROUTE_DNS=0; DO_RUN=0 ;;
    4) DO_SSH=0; DO_INSTALL_CF=0; DO_CREATE_TUNNEL=1; DO_ROUTE_DNS=1; DO_RUN=0 ;;
    5) DO_SSH=0; DO_INSTALL_CF=0; DO_CREATE_TUNNEL=0; DO_ROUTE_DNS=0; DO_RUN=1 ;;
    6) info "See you next time."; exit 0 ;;
    *) error "Invalid choice."; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Step 1: OpenSSH server
# ---------------------------------------------------------------------------
if [[ "$DO_SSH" -eq 1 ]]; then
    title "Installing OpenSSH server"

    if command -v sshd &>/dev/null; then
        ok "OpenSSH server is already installed."
    else
        info "Installing..."
        sudo apt update 2>&1 | tee -a "$LOG_FILE"
        sudo apt install -y openssh-server 2>&1 | tee -a "$LOG_FILE"
        ok "OpenSSH server installed."
    fi

    sudo mkdir -p /run/sshd

    # Standard detection: a system running systemd mounts a cgroup at
    # /run/systemd/system. More reliable than testing the exit code of
    # `systemctl status`, which can fail even when systemd is running,
    # and conversely can exist as a binary without systemd being PID 1
    # (containers/sandboxes, confirmed earlier on this machine).
    if [[ -d /run/systemd/system ]]; then
        info "systemd detected, starting the sshd service."
        sudo systemctl enable --now ssh 2>&1 | tee -a "$LOG_FILE" || \
            sudo systemctl enable --now sshd 2>&1 | tee -a "$LOG_FILE"
    else
        warn "systemd not available (likely a containerized environment)."
        if pgrep -x sshd &>/dev/null; then
            ok "sshd is already running."
        else
            info "Starting sshd manually..."
            sudo /usr/sbin/sshd 2>&1 | tee -a "$LOG_FILE"
            if pgrep -x sshd &>/dev/null; then
                ok "sshd started manually."
            else
                error "Failed to start sshd. Check the log: $LOG_FILE"
            fi
        fi
    fi

    echo
    if confirm "Do you want to set/change the root password now (needed to connect over SSH)?"; then
        sudo passwd root
    else
        warn "Remember to set a root password (or an SSH key) before connecting."
    fi

    echo
    if confirm "Do you want to disable password login in favor of a public key (more secure)?"; then
        PUBKEY=$(ask "Paste your SSH public key (contents of your .pub key)" "")
        if [[ -n "$PUBKEY" ]]; then
            sudo mkdir -p /root/.ssh
            echo "$PUBKEY" | sudo tee -a /root/.ssh/authorized_keys > /dev/null
            sudo chmod 700 /root/.ssh
            sudo chmod 600 /root/.ssh/authorized_keys
            sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
            ok "Key added and password authentication disabled."
            if [[ -d /run/systemd/system ]]; then
                warn "Restart sshd to apply the change: sudo systemctl restart ssh"
            else
                warn "Restart sshd to apply the change: sudo pkill sshd && sudo /usr/sbin/sshd"
            fi
        else
            warn "No key provided, password authentication kept enabled."
        fi
    fi

    ok "SSH step complete."
fi

# ---------------------------------------------------------------------------
# Step 2: Install cloudflared
# ---------------------------------------------------------------------------
if [[ "$DO_INSTALL_CF" -eq 1 ]]; then
    title "Installing cloudflared"

    if command -v cloudflared &>/dev/null; then
        ok "cloudflared is already installed ($(cloudflared --version 2>&1 | head -1))."
    else
        ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
        info "Detected architecture: $ARCH"
        URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
        info "Downloading from: $URL"

        TMP_DEB="/tmp/cloudflared-${ARCH}.deb"
        if curl -fL -o "$TMP_DEB" "$URL" 2>&1 | tee -a "$LOG_FILE"; then
            sudo dpkg -i "$TMP_DEB" 2>&1 | tee -a "$LOG_FILE"
            # Resolve any missing dependencies
            sudo apt-get install -f -y 2>&1 | tee -a "$LOG_FILE"
            rm -f "$TMP_DEB"
        else
            error "Failed to download cloudflared. Check your network connection."
            exit 1
        fi
    fi

    if command -v cloudflared &>/dev/null; then
        ok "cloudflared installed: $(cloudflared --version 2>&1 | head -1)"
    else
        error "cloudflared does not appear to be installed correctly."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 3: Cloudflare login
# ---------------------------------------------------------------------------
if [[ "$DO_CREATE_TUNNEL" -eq 1 ]]; then
    title "Logging in to your Cloudflare account"

    CERT_PATH="$HOME/.cloudflared/cert.pem"
    if [[ -f "$CERT_PATH" ]]; then
        ok "A certificate already exists ($CERT_PATH)."
        if ! confirm "Do you want to log in again anyway (new login)?"; then
            info "Using the existing certificate."
        else
            cloudflared tunnel login
        fi
    else
        info "No certificate found. Starting login."
        info "A URL will be shown: open it in a browser, log in, and authorize your domain."
        cloudflared tunnel login
    fi

    if [[ ! -f "$CERT_PATH" ]]; then
        error "Login failed or was not completed (certificate not found)."
        exit 1
    fi
    ok "Connected to Cloudflare."

    # -----------------------------------------------------------------------
    # Step 4: Create or reuse a tunnel
    # -----------------------------------------------------------------------
    title "Tunnel configuration"

    # jq is required to parse the JSON output reliably.
    if ! command -v jq &>/dev/null; then
        info "jq is not installed (needed to read the tunnel list reliably)."
        sudo apt update 2>&1 | tee -a "$LOG_FILE"
        sudo apt install -y jq 2>&1 | tee -a "$LOG_FILE"
    fi

    get_tunnel_id() {
        # Looks up a tunnel by exact name via JSON output (more reliable than
        # parsing the table format, whose columns are not guaranteed stable).
        cloudflared tunnel list --output json 2>/dev/null | jq -r --arg name "$1" '.[] | select(.name == $name) | .id' | head -1
    }

    TUNNEL_NAME=$(ask "Name of the tunnel to create (or existing one to reuse)" "ssh-sandbox")

    EXISTING_ID=$(get_tunnel_id "$TUNNEL_NAME")

    if [[ -n "$EXISTING_ID" ]]; then
        warn "A tunnel named '$TUNNEL_NAME' already exists (ID: $EXISTING_ID)."
        if confirm "Reuse it?"; then
            TUNNEL_ID="$EXISTING_ID"
        else
            TUNNEL_NAME=$(ask "New tunnel name" "${TUNNEL_NAME}-2")
            cloudflared tunnel create "$TUNNEL_NAME" 2>&1 | tee -a "$LOG_FILE"
            TUNNEL_ID=$(get_tunnel_id "$TUNNEL_NAME")
        fi
    else
        info "Creating tunnel '$TUNNEL_NAME'..."
        cloudflared tunnel create "$TUNNEL_NAME" 2>&1 | tee -a "$LOG_FILE"
        TUNNEL_ID=$(get_tunnel_id "$TUNNEL_NAME")
    fi

    if [[ -z "$TUNNEL_ID" ]]; then
        error "Could not retrieve the tunnel ID. Check the log: $LOG_FILE"
        exit 1
    fi
    ok "Tunnel ready: $TUNNEL_NAME (ID: $TUNNEL_ID)"
fi

# ---------------------------------------------------------------------------
# Step 5: DNS route
# ---------------------------------------------------------------------------
if [[ "$DO_ROUTE_DNS" -eq 1 ]]; then
    title "Domain and subdomain configuration"

    info "Example: to get ssh.jcversanb.dpdns.org, the domain is jcversanb.dpdns.org"
    info "and the subdomain is ssh."
    echo

    while true; do
        DOMAIN=$(ask "Your domain (already added to Cloudflare, e.g. jcversanb.dpdns.org)" "")
        if [[ -z "$DOMAIN" ]]; then
            error "A domain is required to create the DNS route."
        else
            break
        fi
    done

    SUBDOMAIN=$(ask "Subdomain name to use (e.g. ssh)" "ssh")

    # Build the final hostname, avoiding a duplicated dot if the user left
    # the subdomain empty (in which case the root domain is routed).
    if [[ -z "$SUBDOMAIN" ]]; then
        SSH_HOSTNAME="$DOMAIN"
    else
        SSH_HOSTNAME="${SUBDOMAIN}.${DOMAIN}"
    fi

    echo
    info "Final hostname: ${BOLD}${SSH_HOSTNAME}${NC}"
    if ! confirm "Is this correct?"; then
        SSH_HOSTNAME=$(ask "Enter the full hostname you want directly" "$SSH_HOSTNAME")
    fi

    info "DNS route: $SSH_HOSTNAME -> tunnel $TUNNEL_NAME"
    if cloudflared tunnel route dns "$TUNNEL_NAME" "$SSH_HOSTNAME" 2>&1 | tee -a "$LOG_FILE"; then
        ok "DNS route configured."
    else
        warn "The route may already exist, or an error occurred (see $LOG_FILE)."
    fi

    # Save info for the run step and the final summary
    echo "$TUNNEL_NAME" > /tmp/.setup-ssh-tunnel-name
    echo "$SSH_HOSTNAME" > /tmp/.setup-ssh-tunnel-hostname
    echo "$DOMAIN" > /tmp/.setup-ssh-tunnel-domain
fi

# ---------------------------------------------------------------------------
# Step 6: Run the tunnel
# ---------------------------------------------------------------------------
if [[ "$DO_RUN" -eq 1 ]]; then
    title "Running the tunnel"

    if [[ -z "${TUNNEL_NAME:-}" ]]; then
        if [[ -f /tmp/.setup-ssh-tunnel-name ]]; then
            TUNNEL_NAME=$(cat /tmp/.setup-ssh-tunnel-name)
        else
            TUNNEL_NAME=$(ask "Name of the tunnel to run" "ssh-sandbox")
        fi
    fi

    LOCAL_PORT=$(ask "Local port to expose (SSH = 22)" "22")

    echo
    echo "  1) Run in the foreground (the terminal must stay open)"
    echo "  2) Run in the background (nohup, keeps running after you close the terminal)"
    RUN_MODE=$(ask "Run mode (1-2)" "2")

    CMD_ARR=(cloudflared tunnel run --url "ssh://localhost:${LOCAL_PORT}" "${TUNNEL_NAME}")

    if [[ "$RUN_MODE" == "1" ]]; then
        info "Running in the foreground. Press Ctrl+C to stop."
        info "Command: ${CMD_ARR[*]}"
        "${CMD_ARR[@]}"
    else
        NOHUP_LOG="/tmp/cloudflared-${TUNNEL_NAME}.log"
        info "Running in the background. Logs: $NOHUP_LOG"
        nohup "${CMD_ARR[@]}" > "$NOHUP_LOG" 2>&1 &
        TUNNEL_PID=$!
        sleep 3
        if kill -0 "$TUNNEL_PID" 2>/dev/null; then
            ok "Tunnel running in the background (PID: $TUNNEL_PID)."
            info "To stop it later: kill $TUNNEL_PID"
            info "To view the logs: tail -f $NOHUP_LOG"
        else
            error "The tunnel appears to have failed to start. Check: $NOHUP_LOG"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
title "Summary"

HOSTNAME_SAVED=""
[[ -f /tmp/.setup-ssh-tunnel-hostname ]] && HOSTNAME_SAVED=$(cat /tmp/.setup-ssh-tunnel-hostname)

if [[ -z "$HOSTNAME_SAVED" ]]; then
    warn "No hostname known for this session."
    if confirm "Do you want to enter the hostname manually to display the connection command?"; then
        HOSTNAME_SAVED=$(ask "Full hostname (e.g. ssh.jcversanb.dpdns.org)" "")
    fi
fi

if [[ -n "$HOSTNAME_SAVED" ]]; then
    echo -e "${GREEN}To connect over SSH from another device (Termux, PC, etc.):${NC}"
    echo
    echo "  1. Install the required tools on the client device:"
    echo -e "     ${BOLD}pkg install openssh cloudflared${NC}   # (Termux)"
    echo -e "     ${BOLD}sudo apt install openssh-client${NC} + cloudflared   # (Linux/macOS)"
    echo
    echo "  2. Connect with this command:"
    echo -e "     ${BOLD}ssh -o ProxyCommand=\"cloudflared access ssh --hostname ${HOSTNAME_SAVED}\" root@${HOSTNAME_SAVED}${NC}"
    echo
    info "This command works as long as the tunnel is running on the server side (see above)."
fi

ok "Done. Full log available at: $LOG_FILE"
