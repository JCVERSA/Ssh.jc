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

# Validates a pasted string looks like a real SSH public key (OpenSSH format).
# FIX (Medium #7): previously any string was accepted, silently corrupting
# authorized_keys if the paste was malformed.
is_valid_pubkey() {
    [[ "$1" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]
}

# Appends a public key to an authorized_keys file, skipping it if already present.
# FIX (High #6): the original script appended unconditionally, duplicating the
# key on every re-run of the script.
add_key_dedup() {
    local key="$1" path="$2"
    sudo mkdir -p "$(dirname "$path")" || { error "Could not create directory for $path."; return 1; }
    sudo touch "$path" || { error "Could not create $path."; return 1; }
    if sudo grep -qF -- "$key" "$path" 2>/dev/null; then
        info "This key is already present in $path, skipping."
        return 0
    fi
    if ! printf '%s\n' "$key" | sudo tee -a "$path" > /dev/null; then
        error "Failed to write the key to $path."
        return 1
    fi
    if ! sudo grep -qF -- "$key" "$path" 2>/dev/null; then
        error "Key write to $path could not be confirmed after writing."
        return 1
    fi
}

# Validates sshd_config syntax and confirms the EFFECTIVE value of a directive
# actually matches what we just set.
# FIX (High #11 - audit 2): Ubuntu/Debian cloud images ship
# `Include /etc/ssh/sshd_config.d/*.conf` near the top of sshd_config, and
# OpenSSH applies the FIRST occurrence of a directive it encounters. A drop-in
# file (e.g. 50-cloud-init.conf) can therefore silently override a value we
# just `sed`-ed into the main file, while the script would otherwise report
# success. `sshd -T` reports the value sshd will actually use.
#
# FIX (audit 5): "prohibit-password" and "without-password" are the SAME
# effective PermitRootLogin value (OpenSSH kept the old name as an alias for
# backward compatibility; `sshd -T` normalizes to "without-password"). A
# literal string comparison flagged this as a drop-in override on every
# single run, which is a false positive - not a real misconfiguration.
check_sshd_setting() {
    local directive="$1" expected="$2" actual
    if ! sudo sshd -t 2>&1 | tee -a "$LOG_FILE"; then
        error "sshd_config has a syntax error after this change. Fix it before restarting sshd (see $LOG_FILE)."
        return 1
    fi
    actual=$(sudo sshd -T 2>/dev/null | awk -v d="${directive,,}" 'tolower($1)==d {print $2; exit}')

    # Normalize known synonymous values before comparing, so we only warn on
    # an actual mismatch rather than an alias of the same setting.
    local norm_actual="${actual,,}" norm_expected="${expected,,}"
    if [[ "${directive,,}" == "permitrootlogin" ]]; then
        [[ "$norm_actual" == "without-password" ]] && norm_actual="prohibit-password"
        [[ "$norm_expected" == "without-password" ]] && norm_expected="prohibit-password"
    fi

    if [[ -z "$actual" ]]; then
        warn "Could not determine the effective value of $directive (sshd -T). Verify manually after restart."
    elif [[ "$norm_actual" != "$norm_expected" ]]; then
        warn "Effective '$directive' is '$actual', not '$expected' as intended. A drop-in file under /etc/ssh/sshd_config.d/*.conf is likely overriding it (Ubuntu/cloud-init default). Edit that file directly or ensure it's included after sshd_config's own settings."
    else
        ok "Effective '$directive' confirmed as '$actual'."
    fi
}

# Ensures the SFTP subsystem is active. On Ubuntu/Debian, openssh-server
# enables it out of the box (`Subsystem sftp ...` in the default
# sshd_config), so this is normally a no-op; it only intervenes if that line
# was removed/commented (e.g. hardened baseline images). Any user who can
# already log in over SSH (password or key, per the access mode chosen above)
# automatically gets SFTP too - no separate account or key is needed.
ensure_sftp_enabled() {
    # `sshd -T` reports the merged, effective configuration (main file +
    # Include drop-ins), so this reflects reality rather than just the main
    # file's contents.
    if sudo sshd -T 2>/dev/null | grep -qi '^subsystem sftp'; then
        ok "SFTP is already active for any user who can log in over SSH."
        return 0
    fi

    warn "The SFTP subsystem is not active in the current sshd configuration."
    if ! confirm "Enable SFTP now (adds a 'Subsystem sftp' line to /etc/ssh/sshd_config)?"; then
        info "SFTP left disabled."
        return 0
    fi

    local sftp_server=""
    for candidate in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server; do
        [[ -x "$candidate" ]] && { sftp_server="$candidate"; break; }
    done

    if [[ -z "$sftp_server" ]]; then
        error "Could not locate the sftp-server binary. Is openssh-sftp-server installed? Try: sudo apt install -y openssh-sftp-server"
        return 1
    fi

    if grep -qi '^#\?Subsystem[[:space:]]\+sftp' /etc/ssh/sshd_config 2>/dev/null; then
        sudo sed -i "s|^#\?Subsystem[[:space:]]\+sftp.*|Subsystem sftp ${sftp_server}|" /etc/ssh/sshd_config
    else
        echo "Subsystem sftp ${sftp_server}" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi

    if ! sudo sshd -t 2>&1 | tee -a "$LOG_FILE"; then
        error "sshd_config now has a syntax error after adding the SFTP subsystem - DO NOT restart sshd until this is fixed. See $LOG_FILE."
        return 1
    fi

    if sudo sshd -T 2>/dev/null | grep -qi '^subsystem sftp'; then
        ok "SFTP subsystem configured (${sftp_server})."
    else
        warn "Could not confirm SFTP is active after the change. A drop-in file under /etc/ssh/sshd_config.d/*.conf may be interfering. Verify manually: sudo sshd -T | grep -i subsystem"
    fi

    if [[ -d /run/systemd/system ]]; then
        warn "Restart sshd to apply changes: sudo systemctl restart ssh"
    else
        warn "Restart sshd to apply changes: sudo pkill sshd && sudo /usr/sbin/sshd"
    fi
}

# Installs jq if missing. Extracted into a function (FIX Low): was duplicated
# inline and only triggered inside the tunnel-creation step, even though the
# cloudflared checksum verification step now also needs it.
ensure_jq() {
    if ! command -v jq &>/dev/null; then
        info "jq is not installed (needed to parse JSON output reliably)."
        sudo apt update 2>&1 | tee -a "$LOG_FILE"
        sudo apt install -y jq 2>&1 | tee -a "$LOG_FILE"
        if ! command -v jq &>/dev/null; then
            warn "jq installation failed; steps relying on JSON parsing (checksum verification, tunnel ID lookup) will be degraded. Check: $LOG_FILE"
        fi
    fi
}

# Creates a dedicated sudo-capable admin user with SSH key auth.
# FIX (Critical #1): offers a safer alternative to enabling root SSH login
# directly on a tunnel that will be reachable from the public internet.
# Disables PasswordAuthentication in sshd_config, validates the config, and
# reminds the user to restart sshd. Assumes the confirm() prompt already
# happened at the call site (the wording differs slightly between the admin
# user and root flows, so the prompt itself stays at each call site).
# Refactor (audit 4): previously duplicated near-identically in
# create_admin_user and the root-access branch below.
disable_password_auth_confirmed() {
    sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    if sudo sshd -t 2>&1 | tee -a "$LOG_FILE"; then
        ok "Password authentication disabled for all accounts."
        check_sshd_setting "PasswordAuthentication" "no"
        if [[ -d /run/systemd/system ]]; then
            warn "Restart sshd to apply changes: sudo systemctl restart ssh"
        else
            warn "Restart sshd to apply changes: sudo pkill sshd && sudo /usr/sbin/sshd"
        fi
    else
        error "sshd_config now has a syntax error - DO NOT restart sshd until this is fixed, or you may lock yourself out. See $LOG_FILE."
    fi
}

create_admin_user() {
    local username pubkey
    username=$(ask "Username for the new admin account" "admin")

    if id "$username" &>/dev/null; then
        ok "User '$username' already exists."
    else
        sudo useradd -m -s /bin/bash -G sudo "$username" 2>&1 | tee -a "$LOG_FILE"
        if id "$username" &>/dev/null; then
            ok "User '$username' created and added to the 'sudo' group."
        else
            error "Failed to create user '$username'. Check the log: $LOG_FILE"
            return 1
        fi
    fi

    pubkey=$(ask "Paste the SSH public key for '$username' (contents of your .pub key)" "")
    if [[ -n "$pubkey" ]]; then
        if ! is_valid_pubkey "$pubkey"; then
            warn "This doesn't look like a standard SSH public key format. Adding it anyway, but double-check it works before closing this session."
        fi
        if ! add_key_dedup "$pubkey" "/home/$username/.ssh/authorized_keys"; then
            error "Could not add the key for '$username'. Skipping ownership/permission changes and the password-disable prompt below."
        else
            sudo chown -R "${username}:${username}" "/home/$username/.ssh"
            sudo chmod 700 "/home/$username/.ssh"
            sudo chmod 600 "/home/$username/.ssh/authorized_keys"
            ok "Key added for '$username'."

            # FIX (High #14 - audit 3): this path was presented as the
            # "recommended" and secure option, but only added a key for the new
            # user - it never touched PasswordAuthentication. Any other local
            # account with a password (including the one running this script)
            # could still log in with a password once the tunnel made sshd
            # publicly reachable, silently undermining the "recommended" label.
            echo
            if confirm "Disable SSH password authentication for ALL accounts now that '$username' has a key? (recommended - do this only after confirming the key works)"; then
                disable_password_auth_confirmed
            else
                warn "Password authentication left enabled. Any local account with a password can still log in over SSH once the tunnel is public."
            fi
        fi
    else
        warn "No key provided. Set one later (sudo -u $username ssh-import-id ..., or edit /home/$username/.ssh/authorized_keys), or set a password with: sudo passwd $username"
    fi

    state_set user "$username"
}

require_root_tools() {
    if ! command -v sudo &>/dev/null; then
        error "sudo is not available on this system. The script must be run as root or with sudo installed."
        exit 1
    fi
    # FIX (Medium #9): the original script only checked that the `sudo`
    # binary existed, not that the current user can actually use it. This
    # caused late, confusing failures deep into the script instead of a
    # clear failure up front.
    if ! sudo -v 2>/dev/null; then
        error "The current user does not appear to have sudo privileges (or the sudo password was refused)."
        exit 1
    fi
}

# FIX (Medium #15 - audit 3): a predictable filename under the shared,
# world-writable /tmp is a symlink/TOCTOU risk (a local attacker could
# pre-create the path before this script runs). mktemp allocates the file
# atomically with a unique name and 0600 permissions.
LOG_FILE=$(mktemp "/tmp/setup-ssh-tunnel-$(date +%Y%m%d-%H%M%S)-XXXXXX.log" 2>/dev/null)
if [[ -z "$LOG_FILE" ]] || ! touch "$LOG_FILE" 2>/dev/null; then
    error "Cannot create log file under /tmp."
    exit 1
fi

# FIX (Medium #11 - audit 2): cross-step state (created username, tunnel name,
# hostname, PID) used to be written to predictable, world-readable filenames
# directly under /tmp, a directory shared by every local user on the system.
# It now lives under a per-user directory with restrictive permissions.
STATE_DIR="${HOME}/.setup-ssh-tunnel"
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null

# state_set <name> <value>   /   state_get <name>
# Tunnel-agnostic keys (e.g. "user"): stored flat under STATE_DIR, as before.
state_set() { printf '%s\n' "$2" > "${STATE_DIR}/$1"; chmod 600 "${STATE_DIR}/$1" 2>/dev/null; }
state_get() { [[ -f "${STATE_DIR}/$1" ]] && cat "${STATE_DIR}/$1"; }

# tunnel_state_set/get <tunnel_name> <key> [value]
# Per-tunnel keys (name/hostname/domain/pid): namespaced under
# STATE_DIR/tunnels/<tunnel_name>/, so configuring or running a second,
# different tunnel never silently reads or overwrites another tunnel's
# saved hostname/PID. Also updates a "last tunnel used" pointer so flows
# that don't ask for a tunnel name up front (mode 5, Run only) can still
# find the most recently configured tunnel by default.
tunnel_state_set() {
    local tunnel="$1" key="$2" value="$3" dir="${STATE_DIR}/tunnels/$1"
    mkdir -p "$dir" 2>/dev/null
    chmod 700 "$dir" 2>/dev/null
    printf '%s\n' "$value" > "${dir}/${key}"
    chmod 600 "${dir}/${key}" 2>/dev/null
    printf '%s\n' "$tunnel" > "${STATE_DIR}/last_tunnel"
    chmod 600 "${STATE_DIR}/last_tunnel" 2>/dev/null
}
tunnel_state_get() {
    local tunnel="$1" key="$2" path="${STATE_DIR}/tunnels/$1/$2"
    [[ -f "$path" ]] && cat "$path"
}
last_tunnel_used() { state_get "last_tunnel"; }

# FIX (audit 5): parses the fxTunnel client's own stdout/log for the line it
# prints on successful connection, e.g. "TCP: fxtun.dev:10023" or
# "TCP: some-other-host.example:44821". The host is NOT assumed to always be
# fxtun.dev - fxTunnel's backend can hand out a different relay host - so
# this is parsed dynamically from whatever the client actually printed
# rather than hardcoded. Retries briefly since the line only appears a
# second or two after the process starts.
# Prints "host:port" on stdout and returns 0 on success, or returns 1 if the
# line never appeared within the timeout.
parse_fxtunnel_endpoint() {
    local log_path="$1" tries="${2:-10}" delay="${3:-1}" line i
    for (( i=0; i<tries; i++ )); do
        # Matches "TCP: <host>:<port>" (host can be a hostname or IP; port is
        # digits only). -m1 stops at the first match found in the file.
        line=$(grep -m1 -oE 'TCP:[[:space:]]+[A-Za-z0-9.-]+:[0-9]+' "$log_path" 2>/dev/null)
        if [[ -n "$line" ]]; then
            # Strip the "TCP:" prefix and surrounding whitespace, leaving
            # "host:port".
            line="${line#TCP:}"
            line="${line# }"
            printf '%s\n' "$line"
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

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
        # FIX (High #5): the original script never re-checked success after
        # this install and would blindly try to start a possibly-missing
        # service.
        if command -v sshd &>/dev/null; then
            ok "OpenSSH server installed."
        else
            error "openssh-server installation failed. Check the log: $LOG_FILE"
            exit 1
        fi
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
    # FIX (Critical #1 + #2): the original flow set a root password and
    # advertised root SSH login in the final summary, but never touched
    # PermitRootLogin (Ubuntu/Debian default: "prohibit-password"), so the
    # promised root/password login would silently fail over SSH. It also
    # offered no safer alternative before exposing SSH on a public tunnel.
    warn "SECURITY: once the tunnel is running, SSH will be reachable from the public internet via your Cloudflare hostname, with no extra login wall unless you separately configure Cloudflare Access."
    echo "  1) Create a dedicated admin user with an SSH key (recommended)"
    echo "  2) Configure root access (password and/or key) - legacy, less secure"
    echo "  3) Skip user/access configuration for now"
    ACCESS_MODE=$(ask "Choice (1-3)" "1")

    case "$ACCESS_MODE" in
        1)
            create_admin_user
            ;;
        2)
            if confirm "Are you sure you want to enable root SSH access? A dedicated user (option 1) is safer."; then
                if confirm "Do you want to set/change the root password now?"; then
                    sudo passwd root
                    if confirm "Allow root to log in WITH THIS PASSWORD over SSH? (sets PermitRootLogin yes - without this, the password only works locally)"; then
                        sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
                        warn "PermitRootLogin set to 'yes'. Root + password over a public tunnel is a significant exposure; consider adding a key and disabling password auth below."
                        check_sshd_setting "PermitRootLogin" "yes"
                    else
                        sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
                        info "PermitRootLogin left as 'prohibit-password': the root password will work locally (console) but NOT over SSH. Add a key below, or use option 1."
                        check_sshd_setting "PermitRootLogin" "prohibit-password"
                    fi
                else
                    warn "Remember to set a root password (or an SSH key) before connecting."
                fi

                echo
                if confirm "Do you want to add an SSH public key for root (more secure than password)?"; then
                    PUBKEY=$(ask "Paste your SSH public key (contents of your .pub key)" "")
                    if [[ -n "$PUBKEY" ]]; then
                        if ! is_valid_pubkey "$PUBKEY"; then
                            warn "This doesn't look like a standard SSH public key format. Adding it anyway, but double-check it works before closing this session."
                        fi
                        if ! add_key_dedup "$PUBKEY" "/root/.ssh/authorized_keys"; then
                            error "Could not add the key for root. Skipping sshd_config changes below."
                        else
                            sudo chmod 700 /root/.ssh
                            sudo chmod 600 /root/.ssh/authorized_keys
                            sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
                            ok "Key added for root (PermitRootLogin set to 'prohibit-password': key-only)."
                            check_sshd_setting "PermitRootLogin" "prohibit-password"
                            if confirm "Disable password login entirely now that a key is configured? (recommended)"; then
                                sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
                                ok "Password authentication disabled."
                                check_sshd_setting "PasswordAuthentication" "no"
                            fi
                            # FIX (Medium #12 - audit 2): validate config syntax before
                            # inviting the user to restart sshd, instead of assuming the
                            # sed edits always leave a valid file.
                            if sudo sshd -t 2>&1 | tee -a "$LOG_FILE"; then
                                if [[ -d /run/systemd/system ]]; then
                                    warn "Restart sshd to apply changes: sudo systemctl restart ssh"
                                else
                                    warn "Restart sshd to apply changes: sudo pkill sshd && sudo /usr/sbin/sshd"
                                fi
                            else
                                error "sshd_config now has a syntax error - DO NOT restart sshd until this is fixed, or you may lock yourself out. See $LOG_FILE."
                            fi
                        fi
                    else
                        warn "No key provided, current settings kept."
                    fi
                fi
            else
                info "Root access configuration skipped."
            fi
            ;;
        *)
            info "User/access configuration skipped."
            ;;
    esac

    echo
    ensure_sftp_enabled

    ok "SSH step complete."
fi

# ---------------------------------------------------------------------------
# Step 2: Install the tunnel client (cloudflared or fxTunnel)
# ---------------------------------------------------------------------------
if [[ "$DO_INSTALL_CF" -eq 1 ]]; then
    title "Tunnel provider"

    echo "  1) Cloudflare Tunnel (cloudflared)"
    echo "  2) fxTunnel (fxtun.dev - SaaS, TCP tunnel with a token)"
    TUNNEL_PROVIDER_CHOICE=$(ask "Choice (1-2)" "1")
    case "$TUNNEL_PROVIDER_CHOICE" in
        2) TUNNEL_PROVIDER="fxtunnel" ;;
        *) TUNNEL_PROVIDER="cloudflared" ;;
    esac
    # Remembered so later steps (run) know which provider was set up in
    # this session even if invoked as a separate menu choice.
    state_set provider "$TUNNEL_PROVIDER"

if [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
    title "Installing fxTunnel"

    if command -v fxtunnel &>/dev/null; then
        ok "fxTunnel is already installed ($(fxtunnel --version 2>&1 | head -1))."
    else
        info "Downloading the fxTunnel installer from https://fxtun.dev/install.sh ..."
        FX_INSTALLER_TMP=$(mktemp "/tmp/fxtunnel-install-XXXXXX.sh")
        if ! curl -fsSL "https://fxtun.dev/install.sh" -o "$FX_INSTALLER_TMP" 2>&1 | tee -a "$LOG_FILE"; then
            error "Failed to download the fxTunnel installer. Check your network connection."
            rm -f "$FX_INSTALLER_TMP"
            exit 1
        fi

        # FIX (parity with cloudflared's Critical #1 checksum guard):
        # fxtun.dev publishes a per-release checksums.txt (fixed file per
        # tag on GitHub Releases), which is a stronger integrity signal
        # than cloudflared's API-digest lookup since it doesn't depend on
        # the GitHub API being reachable/unrate-limited at install time.
        # The installer script itself is served from the website, not a
        # release asset, so it has no published checksum; require explicit
        # confirmation before running it as-is, consistent with how an
        # unverified cloudflared package is handled above.
        warn "No published checksum is available for the install.sh script itself (only release binaries have checksums.txt); it will run with your current shell privileges."
        if ! confirm "Review $FX_INSTALLER_TMP now if you want, then proceed with running it?"; then
            error "Installation aborted by user (unverified installer script)."
            rm -f "$FX_INSTALLER_TMP"
            exit 1
        fi

        if sh "$FX_INSTALLER_TMP" 2>&1 | tee -a "$LOG_FILE"; then
            ok "fxTunnel installer completed."
        else
            error "fxTunnel installer exited with an error. Check the log: $LOG_FILE"
            rm -f "$FX_INSTALLER_TMP"
            exit 1
        fi
        rm -f "$FX_INSTALLER_TMP"
    fi

    if command -v fxtunnel &>/dev/null; then
        # FIX (audit 5): newer fxtunnel builds reject "--version" ("unknown
        # flag") - the confirmation line used to print that error text
        # instead of an actual version. Try "fxtunnel version" (no dashes,
        # the current subcommand) first and fall back to the old flag for
        # older installs, so this still degrades gracefully either way.
        FX_VER=$(fxtunnel version 2>&1 | head -1)
        if [[ -z "$FX_VER" || "$FX_VER" == *"unknown"* || "$FX_VER" == *"Error"* ]]; then
            FX_VER=$(fxtunnel --version 2>&1 | head -1)
        fi
        ok "fxTunnel installed: $FX_VER"
    else
        error "fxtunnel does not appear to be installed correctly (not found in PATH)."
        warn "If install.sh placed it under ~/.local/bin, open a new shell or run: export PATH=\$PATH:\$HOME/.local/bin"
        exit 1
    fi
else
    title "Installing cloudflared"

    if command -v cloudflared &>/dev/null; then
        ok "cloudflared is already installed ($(cloudflared --version 2>&1 | head -1))."
    else
        # FIX (Low #18 - audit 3): a failed detection used to fall back to
        # "amd64" silently, which could download the wrong package on a
        # non-amd64 host with no dpkg. Now it's an explicit, visible warning.
        if ARCH=$(dpkg --print-architecture 2>/dev/null) && [[ -n "$ARCH" ]]; then
            info "Detected architecture: $ARCH"
        else
            ARCH="amd64"
            warn "Could not detect architecture via dpkg; defaulting to amd64. If this host is not x86_64, cancel and check manually."
        fi
        ASSET_NAME="cloudflared-linux-${ARCH}.deb"
        # FIX (Medium #1 - audit 4): "releases/latest" makes installs
        # non-reproducible across time (two runs on different dates can
        # silently pull different cloudflared versions). Let the user pin a
        # specific tag; default to latest to keep the previous behavior for
        # anyone who just wants the newest release.
        CF_VERSION=$(ask "cloudflared version to install (e.g. 2025.6.0), or leave empty for latest" "")
        if [[ -n "$CF_VERSION" ]]; then
            URL="https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/${ASSET_NAME}"
        else
            URL="https://github.com/cloudflare/cloudflared/releases/latest/download/${ASSET_NAME}"
        fi
        info "Downloading from: $URL"

        # FIX (Medium #15 - audit 3): predictable /tmp path replaced with
        # mktemp for the same symlink/TOCTOU reason as LOG_FILE above - this
        # file is about to be installed as root via sudo dpkg -i.
        TMP_DEB=$(mktemp "/tmp/cloudflared-${ARCH}-XXXXXX.deb")

        if curl -fL -o "$TMP_DEB" "$URL" 2>&1 | tee -a "$LOG_FILE"; then
            # FIX (Critical #3): verify integrity when GitHub publishes a
            # digest for the asset, instead of trusting the download blindly.
            ensure_jq
            EXPECTED_SHA=""
            if command -v jq &>/dev/null; then
                if [[ -n "$CF_VERSION" ]]; then
                    CF_RELEASE_API="https://api.github.com/repos/cloudflare/cloudflared/releases/tags/${CF_VERSION}"
                else
                    CF_RELEASE_API="https://api.github.com/repos/cloudflare/cloudflared/releases/latest"
                fi
                EXPECTED_SHA=$(curl -fsSL "$CF_RELEASE_API" 2>/dev/null \
                    | jq -r --arg name "$ASSET_NAME" '.assets[]? | select(.name == $name) | (.digest // empty)' 2>/dev/null \
                    | sed -n 's/^sha256://p')
            fi
            if [[ -n "$EXPECTED_SHA" ]]; then
                ACTUAL_SHA=$(sha256sum "$TMP_DEB" | awk '{print $1}')
                if [[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]]; then
                    ok "Checksum verified (sha256)."
                else
                    error "Checksum mismatch for $ASSET_NAME (expected $EXPECTED_SHA, got $ACTUAL_SHA). Aborting."
                    rm -f "$TMP_DEB"
                    exit 1
                fi
            else
                warn "No published checksum available via the GitHub API for this asset (rate limit, network issue, or API change). Integrity cannot be verified beyond the HTTPS download itself."
                if ! confirm "Install this UNVERIFIED package anyway?"; then
                    error "Installation aborted by user (unverified package)."
                    rm -f "$TMP_DEB"
                    exit 1
                fi
                warn "Proceeding with an unverified package, as confirmed."
            fi

            sudo dpkg -i "$TMP_DEB" 2>&1 | tee -a "$LOG_FILE"
            # Resolve any missing dependencies
            sudo apt-get install -f -y 2>&1 | tee -a "$LOG_FILE"
            rm -f "$TMP_DEB"
        else
            error "Failed to download cloudflared. Check your network connection."
            rm -f "$TMP_DEB"
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
fi

# ---------------------------------------------------------------------------
# Step 3: Cloudflare login / fxTunnel token
# ---------------------------------------------------------------------------
if [[ "$DO_CREATE_TUNNEL" -eq 1 ]]; then

    if [[ -z "${TUNNEL_PROVIDER:-}" ]]; then
        TUNNEL_PROVIDER=$(state_get provider)
        if [[ -z "$TUNNEL_PROVIDER" ]]; then
            echo "  1) Cloudflare Tunnel (cloudflared)"
            echo "  2) fxTunnel (fxtun.dev - SaaS, TCP tunnel with a token)"
            TUNNEL_PROVIDER_CHOICE=$(ask "Which provider is this for? (1-2)" "1")
            case "$TUNNEL_PROVIDER_CHOICE" in
                2) TUNNEL_PROVIDER="fxtunnel" ;;
                *) TUNNEL_PROVIDER="cloudflared" ;;
            esac
            state_set provider "$TUNNEL_PROVIDER"
        fi
    fi

if [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
    title "fxTunnel account token"

    info "Generate a token from your fxtun.dev dashboard (sign up / log in, then create an API token)."
    FX_TOKEN=""
    while true; do
        FX_TOKEN=$(ask "fxTunnel token (starts with sk_)" "")
        if [[ -z "$FX_TOKEN" ]]; then
            error "A token is required to use fxTunnel."
        else
            break
        fi
    done

    TUNNEL_NAME=$(ask "Name to identify this tunnel locally (used only for this script's own bookkeeping)" "ssh-sandbox")

    tunnel_state_set "$TUNNEL_NAME" name "$TUNNEL_NAME"
    tunnel_state_set "$TUNNEL_NAME" token "$FX_TOKEN"
    ok "Token saved for tunnel '$TUNNEL_NAME'."
    info "fxTunnel (SaaS) assigns its public host/port dynamically when the tunnel starts; there is no DNS route to configure here (unlike Cloudflare Tunnel)."
else
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

    ensure_jq

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
fi

# ---------------------------------------------------------------------------
# Step 5: DNS route
# ---------------------------------------------------------------------------
if [[ "$DO_ROUTE_DNS" -eq 1 ]] && [[ "${TUNNEL_PROVIDER:-cloudflared}" != "fxtunnel" ]]; then
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

    # Save info for the run step and the final summary (namespaced per
    # tunnel - see tunnel_state_set above).
    tunnel_state_set "$TUNNEL_NAME" name "$TUNNEL_NAME"
    tunnel_state_set "$TUNNEL_NAME" hostname "$SSH_HOSTNAME"
    tunnel_state_set "$TUNNEL_NAME" domain "$DOMAIN"
fi

# ---------------------------------------------------------------------------
# Step 6: Run the tunnel
# ---------------------------------------------------------------------------
if [[ "$DO_RUN" -eq 1 ]]; then
    title "Running the tunnel"

    if [[ -z "${TUNNEL_NAME:-}" ]]; then
        SAVED_NAME=$(last_tunnel_used)
        if [[ -n "$SAVED_NAME" ]]; then
            info "Using the last configured tunnel: $SAVED_NAME"
            TUNNEL_NAME="$SAVED_NAME"
        else
            TUNNEL_NAME=$(ask "Name of the tunnel to run" "ssh-sandbox")
        fi
    fi

    # Recover the provider chosen for this tunnel when running standalone
    # (e.g. menu option 5) without having gone through steps 2-4 in this
    # same invocation.
    if [[ -z "${TUNNEL_PROVIDER:-}" ]]; then
        TUNNEL_PROVIDER=$(state_get provider)
        [[ -z "$TUNNEL_PROVIDER" ]] && TUNNEL_PROVIDER="cloudflared"
    fi

    # FIX (Low #13 - audit 2): the port was previously accepted as-is with no
    # validation, so a typo would silently produce a broken tunnel URL.
    while true; do
        LOCAL_PORT=$(ask "Local port to expose (SSH = 22)" "22")
        # FIX (Low #17 - audit 3): bash arithmetic treats a leading-zero
        # numeral (e.g. "022") as octal, which could validate/reject a port
        # differently from its plain decimal reading. Force base 10.
        if [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && (( 10#$LOCAL_PORT >= 1 && 10#$LOCAL_PORT <= 65535 )); then
            break
        fi
        error "Invalid port: '$LOCAL_PORT'. Enter a number between 1 and 65535."
    done

    echo
    echo "  1) Run in the foreground (the terminal must stay open)"
    echo "  2) Run in the background (nohup - stops on reboot)"
    if [[ -d /run/systemd/system ]]; then
        echo "  3) Install as a systemd service (recommended - survives reboots)"
        RUN_MODE=$(ask "Run mode (1-3)" "3")
    else
        warn "systemd not available here: option 3 won't work on this system."
        RUN_MODE=$(ask "Run mode (1-2)" "2")
    fi

    SERVICE_LABEL="cloudflared"

    if [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
        SERVICE_LABEL="fxtunnel"
        if [[ -z "${FX_TOKEN:-}" ]]; then
            FX_TOKEN=$(tunnel_state_get "$TUNNEL_NAME" token)
        fi
        if [[ -z "$FX_TOKEN" ]]; then
            error "No fxTunnel token found for '$TUNNEL_NAME'. Re-run this script's tunnel setup step (menu option 4) first."
            exit 1
        fi
        CMD_ARR=(fxtunnel tcp "${LOCAL_PORT}" -t "${FX_TOKEN}")
    else
        CMD_ARR=(cloudflared tunnel run --url "ssh://localhost:${LOCAL_PORT}" "${TUNNEL_NAME}")
    fi

    # FIX (High #4): the original script only offered nohup, which does not
    # survive a VPS reboot - a real problem for what is meant to be a
    # permanent access method. This adds a proper systemd-managed option.
    if [[ "$RUN_MODE" == "3" ]] && [[ "$TUNNEL_PROVIDER" != "fxtunnel" ]]; then
        ensure_jq
        if [[ -z "${TUNNEL_ID:-}" ]]; then
            TUNNEL_ID=$(cloudflared tunnel list --output json 2>/dev/null | jq -r --arg name "$TUNNEL_NAME" '.[] | select(.name == $name) | .id' | head -1)
        fi
        CRED_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"

        if [[ -z "$TUNNEL_ID" ]] || [[ ! -f "$CRED_FILE" ]]; then
            error "Could not find the tunnel credentials file ($CRED_FILE). Cannot install the systemd service."
            if [[ -z "$TUNNEL_ID" ]]; then
                warn "No tunnel named '$TUNNEL_NAME' was found for this Cloudflare account/machine. Run 'cloudflared tunnel list' to check the exact name, or re-run this script's tunnel-creation step (menu option 4)."
            else
                warn "The tunnel exists (ID: $TUNNEL_ID) but its credentials file is missing locally, likely because it was created on a different machine. Re-run 'cloudflared tunnel create $TUNNEL_NAME' on this machine, or copy the credentials file from the machine where it was created."
            fi
            warn "Falling back to background mode."
            RUN_MODE=2
        else
            info "Writing /etc/cloudflared/config.yml ..."
            sudo mkdir -p /etc/cloudflared
            sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CRED_FILE}
url: ssh://localhost:${LOCAL_PORT}
EOF
            if sudo cloudflared service install 2>&1 | tee -a "$LOG_FILE" && \
               sudo systemctl enable --now cloudflared 2>&1 | tee -a "$LOG_FILE"; then
                sleep 2
                if systemctl is-active --quiet cloudflared; then
                    ok "cloudflared installed and running as a systemd service."
                    info "Manage it with: sudo systemctl {status|restart|stop} cloudflared"
                    info "Logs: sudo journalctl -u cloudflared -f"
                else
                    error "The cloudflared service does not look active. Check: sudo journalctl -u cloudflared -e"
                fi
            else
                error "Failed to install/start the cloudflared systemd service."
                warn "Falling back to background mode."
                RUN_MODE=2
            fi
        fi
    elif [[ "$RUN_MODE" == "3" ]] && [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
        # fxTunnel has no built-in "service install" subcommand (unlike
        # cloudflared); write a plain systemd unit instead. The token is
        # passed via an Environment= line in a root-only-readable unit file
        # rather than embedded in ExecStart, so it doesn't leak through
        # `ps aux` / world-readable ExecStart in `systemctl cat`.
        UNIT_NAME="fxtunnel-${TUNNEL_NAME}"
        FXTUNNEL_BIN_PATH=$(command -v fxtunnel)
        if [[ -z "$FXTUNNEL_BIN_PATH" ]]; then
            error "fxtunnel binary not found in PATH. Cannot install the systemd service."
            warn "Falling back to background mode."
            RUN_MODE=2
        else
            info "Writing /etc/systemd/system/${UNIT_NAME}.service ..."
            sudo tee "/etc/systemd/system/${UNIT_NAME}.service" > /dev/null <<EOF
[Unit]
Description=fxTunnel (${TUNNEL_NAME}) - TCP tunnel for local port ${LOCAL_PORT}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=FXTUNNEL_TOKEN=${FX_TOKEN}
ExecStart=${FXTUNNEL_BIN_PATH} tcp ${LOCAL_PORT} -t \${FXTUNNEL_TOKEN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            sudo chmod 600 "/etc/systemd/system/${UNIT_NAME}.service"
            if sudo systemctl daemon-reload 2>&1 | tee -a "$LOG_FILE" && \
               sudo systemctl enable --now "$UNIT_NAME" 2>&1 | tee -a "$LOG_FILE"; then
                sleep 2
                if systemctl is-active --quiet "$UNIT_NAME"; then
                    ok "fxTunnel installed and running as a systemd service ($UNIT_NAME)."
                    info "Manage it with: sudo systemctl {status|restart|stop} $UNIT_NAME"
                    info "Logs: sudo journalctl -u $UNIT_NAME -f"
                    # FIX (audit 5): systemd mode also parses the endpoint,
                    # same as background mode, so the final summary can show
                    # a ready-to-use ssh command instead of just "check
                    # journalctl".
                    FX_ENDPOINT=$(parse_fxtunnel_endpoint <(sudo journalctl -u "$UNIT_NAME" --no-pager -n 50) 5 1 || true)
                    if [[ -n "$FX_ENDPOINT" ]]; then
                        tunnel_state_set "$TUNNEL_NAME" fx_endpoint "$FX_ENDPOINT"
                    fi
                else
                    error "The $UNIT_NAME service does not look active. Check: sudo journalctl -u $UNIT_NAME -e"
                fi
            else
                error "Failed to install/start the $UNIT_NAME systemd service."
                warn "Falling back to background mode."
                RUN_MODE=2
            fi
        fi
    fi

    if [[ "$RUN_MODE" == "1" ]]; then
        info "Running in the foreground. Press Ctrl+C to stop."
        if [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
            info "Command: fxtunnel tcp ${LOCAL_PORT} -t <token>"
        else
            info "Command: ${CMD_ARR[*]}"
        fi
        "${CMD_ARR[@]}"
    elif [[ "$RUN_MODE" == "2" ]]; then
        NOHUP_LOG=$(mktemp "/tmp/${SERVICE_LABEL}-${TUNNEL_NAME}-XXXXXX.log")
        info "Running in the background. Logs: $NOHUP_LOG"
        nohup "${CMD_ARR[@]}" > "$NOHUP_LOG" 2>&1 &
        TUNNEL_PID=$!
        sleep 3
        if kill -0 "$TUNNEL_PID" 2>/dev/null; then
            ok "Tunnel running in the background (PID: $TUNNEL_PID)."
            # FIX (Medium #8): the PID used to only be printed to the
            # terminal, with no way to retrieve it in a later session.
            tunnel_state_set "$TUNNEL_NAME" pid "$TUNNEL_PID"
            tunnel_state_set "$TUNNEL_NAME" log "$NOHUP_LOG"
            info "To stop it later: kill \$(cat \"${STATE_DIR}/tunnels/${TUNNEL_NAME}/pid\")"
            info "To view the logs: tail -f $NOHUP_LOG"
            if [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
                # FIX (audit 5): previously this only told the user to go
                # check the log manually. Now the script itself waits for
                # and parses the "TCP: host:port" line fxTunnel prints on
                # startup, so the final summary can show a ready-to-use ssh
                # command - the same experience as the Cloudflare path.
                info "Waiting for fxTunnel to report its assigned public endpoint..."
                FX_ENDPOINT=$(parse_fxtunnel_endpoint "$NOHUP_LOG" 10 1 || true)
                if [[ -n "$FX_ENDPOINT" ]]; then
                    tunnel_state_set "$TUNNEL_NAME" fx_endpoint "$FX_ENDPOINT"
                    ok "fxTunnel endpoint detected: $FX_ENDPOINT"
                else
                    warn "Could not detect the endpoint automatically within the timeout. Check the log manually: tail -f $NOHUP_LOG"
                fi
            fi
        else
            error "The tunnel appears to have failed to start. Check: $NOHUP_LOG"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
title "Summary"

if [[ -z "${TUNNEL_PROVIDER:-}" ]]; then
    TUNNEL_PROVIDER=$(state_get provider)
    [[ -z "$TUNNEL_PROVIDER" ]] && TUNNEL_PROVIDER="cloudflared"
fi

# FIX (Medium #16 - audit 3): CONNECT_USER used to default to "root" even
# when access configuration was explicitly skipped (ACCESS_MODE 3), which
# advertised a login that was never actually configured. Track whether any
# access setup actually happened and say so plainly if not.
CONNECT_USER="root"
SAVED_USER=$(state_get user)
if [[ -n "$SAVED_USER" ]]; then
    CONNECT_USER="$SAVED_USER"
elif [[ "${ACCESS_MODE:-}" != "2" ]]; then
    warn "No SSH access (user or root) was configured in this run. The command below is a template only - set up a login first (re-run and choose option 1 or 2), or it will fail."
fi

if [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
    # FIX (audit 5): if the background/systemd run step above managed to
    # parse the "TCP: host:port" line fxTunnel prints on startup, show the
    # ready-to-use ssh command directly - matching the Cloudflare summary's
    # behavior - instead of always telling the user to go check a log by
    # hand. Falls back to the old generic instructions if parsing failed or
    # this is a fresh "run only" invocation with no state saved yet.
    FX_ENDPOINT_SAVED=""
    if [[ -n "${TUNNEL_NAME:-}" ]]; then
        FX_ENDPOINT_SAVED=$(tunnel_state_get "$TUNNEL_NAME" fx_endpoint)
    fi
    if [[ -z "$FX_ENDPOINT_SAVED" ]]; then
        SAVED_NAME_FOR_SUMMARY=$(last_tunnel_used)
        [[ -n "$SAVED_NAME_FOR_SUMMARY" ]] && FX_ENDPOINT_SAVED=$(tunnel_state_get "$SAVED_NAME_FOR_SUMMARY" fx_endpoint)
    fi

    if [[ -n "$FX_ENDPOINT_SAVED" ]]; then
        FX_HOST_SAVED="${FX_ENDPOINT_SAVED%:*}"
        FX_PORT_SAVED="${FX_ENDPOINT_SAVED##*:}"
        echo -e "${GREEN}fxTunnel is up. Detected public endpoint: ${BOLD}${FX_ENDPOINT_SAVED}${NC}"
        echo
        echo "Connect over SSH from another device with:"
        echo -e "     ${BOLD}ssh -p ${FX_PORT_SAVED} ${CONNECT_USER}@${FX_HOST_SAVED}${NC}"
        echo
        echo "For file transfer (SFTP), same host/port, same key:"
        echo -e "     ${BOLD}sftp -P ${FX_PORT_SAVED} ${CONNECT_USER}@${FX_HOST_SAVED}${NC}"
        echo
        warn "Reminder: this host:port is reachable by anyone on the internet who knows it. fxTunnel may assign a different port on a future restart - re-run this script (menu option 5) or check the log to confirm the current one."
    else
        echo -e "${GREEN}fxTunnel (SaaS) does not assign a fixed hostname.${NC}"
        echo "The public host and port are printed by the fxtunnel client itself when the"
        echo "tunnel starts - check the foreground output, the background log shown above,"
        echo "or 'sudo journalctl -u fxtunnel-<name> -f' if installed as a systemd service."
        echo
        echo "Once you have that host:port, connect with:"
        echo -e "     ${BOLD}ssh -p <port> ${CONNECT_USER}@<host>${NC}"
        echo
        warn "Reminder: this port is reachable by anyone on the internet who knows it."
    fi
else
    HOSTNAME_SAVED=""
    if [[ -n "${TUNNEL_NAME:-}" ]]; then
        HOSTNAME_SAVED=$(tunnel_state_get "$TUNNEL_NAME" hostname)
    fi
    if [[ -z "$HOSTNAME_SAVED" ]]; then
        SAVED_NAME_FOR_SUMMARY=$(last_tunnel_used)
        [[ -n "$SAVED_NAME_FOR_SUMMARY" ]] && HOSTNAME_SAVED=$(tunnel_state_get "$SAVED_NAME_FOR_SUMMARY" hostname)
    fi

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
        echo -e "     ${BOLD}ssh -o ProxyCommand=\"cloudflared access ssh --hostname ${HOSTNAME_SAVED}\" ${CONNECT_USER}@${HOSTNAME_SAVED}${NC}"
        echo
        echo "  3. For file transfer (SFTP), same principle, same tunnel and same key:"
        echo -e "     ${BOLD}sftp -o ProxyCommand=\"cloudflared access ssh --hostname ${HOSTNAME_SAVED}\" ${CONNECT_USER}@${HOSTNAME_SAVED}${NC}"
        echo -e "     Or with a graphical client (FileZilla, WinSCP, Cyberduck...): protocol SFTP, host ${HOSTNAME_SAVED},"
        echo -e "     user ${CONNECT_USER}, and the same ProxyCommand configured as an external SFTP/SSH proxy option."
        echo
        info "This command works as long as the tunnel is running on the server side (see above)."
        warn "Reminder: this hostname is reachable by anyone on the internet. For stronger protection, add a Cloudflare Access policy in front of it (Zero Trust dashboard)."
    fi
fi

ok "Done. Full log available at: $LOG_FILE"
