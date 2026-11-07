#!/usr/bin/env bash
# Offline OpenSSH setup and local-network connection guidance for Debian/Ubuntu.
# Existing SSH, firewall, and tunnel configurations are not edited.
set -uo pipefail

export PATH="$PATH:/usr/sbin:/sbin"

usage() {
    cat <<'USAGE'
Usage: ./Install.sh [--help]

Install OpenSSH server from packages already cached locally, if needed, start
it, and display suggested SSH/SFTP commands for a local IPv4 address.
The script does not update package indexes or ask APT to download packages.
APT hooks and package scripts are not controlled by this script: use a
network-isolated machine if strictly offline operation is required.
The script does not directly edit SSH, firewall, or tunnel configuration;
package installation may change the system, install dependencies, or start SSH.
USAGE
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    usage
    exit 0
fi
if (( $# != 0 )); then
    usage >&2
    exit 1
fi

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

# Installation can start SSH through package scripts, so ask before either
# installing or starting it. Never change firewall or SSH policy implicitly.
exposure_confirmed=0
confirm_exposure() {
    (( exposure_confirmed == 1 )) && return 0
    warn 'SSH may listen on public or other non-LAN interfaces, depending on existing SSH, firewall, and network settings.'
    warn 'This script does not restrict SSH access to the local network.'
    printf 'Continue with SSH installation or startup? [y/N]: '
    local answer
    if ! IFS= read -r answer; then
        error 'Input ended before confirmation. No SSH installation or startup was attempted.'
        return 1
    fi
    if [[ ! "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]; then
        info 'Cancelled without attempting SSH installation or startup.'
        return 1
    fi
    exposure_confirmed=1
}

# Root can run directly; otherwise request sudo without attempting to install it.
if (( EUID == 0 )); then
    AS_ROOT=()
elif command -v sudo >/dev/null 2>&1; then
    AS_ROOT=(sudo)
    if ! sudo -v; then
        error 'Sudo authentication failed.'
        exit 1
    fi
else
    error 'Run as root or use an account with sudo already installed.'
    exit 1
fi

if ! command -v sshd >/dev/null 2>&1; then
    if ! command -v apt-get >/dev/null 2>&1; then
        error 'OpenSSH server is missing and apt-get is unavailable. Install it from trusted offline media, then rerun.'
        exit 1
    fi
    info 'OpenSSH server is missing. APT will use locally cached packages and existing package indexes; package downloads are disabled.'
    warn 'Installation may install or upgrade dependencies, run package scripts, and start SSH or change system state.'
    warn 'APT hooks and package scripts may access the network. For strictly offline operation, isolate the machine from all networks before installation.'
    confirm_exposure || exit 1
    if ! "${AS_ROOT[@]}" apt-get --no-download install -y openssh-server; then
        error 'Offline installation failed. Ensure current APT package indexes and all required packages and dependencies are available locally, or install them from trusted offline media, then rerun.'
        exit 1
    fi
    hash -r
    if ! command -v sshd >/dev/null 2>&1; then
        error 'OpenSSH installation completed but sshd was not found in PATH.'
        exit 1
    fi
fi
info 'OpenSSH server is installed.'

# Do not rewrite configuration or change service enablement. A socket-activated
# SSH service may be idle until a connection arrives, so check the socket too.
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet ssh.service 2>/dev/null || \
       systemctl is-active --quiet sshd.service 2>/dev/null || \
       systemctl is-active --quiet ssh.socket 2>/dev/null || \
       systemctl is-active --quiet sshd.socket 2>/dev/null; then
        info 'SSH service or socket is active.'
    else
        info 'SSH is not active. Starting the existing SSH service will leave boot enablement unchanged.'
        confirm_exposure || exit 1
        if ! "${AS_ROOT[@]}" systemctl start ssh.service && \
           ! "${AS_ROOT[@]}" systemctl start sshd.service; then
            error 'Could not start the SSH service. Check the system service logs and configuration.'
            exit 1
        fi
    fi
else
    if command -v pgrep >/dev/null 2>&1 && pgrep -x sshd >/dev/null 2>&1; then
        info 'An sshd process is already running.'
    else
        info 'Starting sshd without systemd; it may not survive a reboot.'
        confirm_exposure || exit 1
        if ! "${AS_ROOT[@]}" sshd; then
            error 'Could not start sshd. Check its configuration and runtime requirements.'
            exit 1
        fi
    fi
fi

addresses=()
if command -v ip >/dev/null 2>&1; then
    mapfile -t addresses < <(ip -o -4 addr show up scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1] " (" $2 ")"}')
fi
address='<server-ip>'
if (( ${#addresses[@]} > 0 )); then
    printf '\nAvailable IPv4 addresses (select one reachable from your client):\n'
    for i in "${!addresses[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${addresses[$i]}"
    done
    while :; do
        printf 'Address number [1]: '
        if ! IFS= read -r choice; then
            error 'Input ended before an address was selected.'
            exit 1
        fi
        choice=${choice:-1}
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( ${#choice} <= 4 )) && (( choice <= ${#addresses[@]} )); then
            address=${addresses[$((choice - 1))]%% *}
            break
        fi
        warn 'Invalid address selection.'
    done
else
    warn 'No suitable IPv4 address detected. Replace <server-ip> with a reachable address.'
fi

# Configuration may differ from a running daemon or a systemd socket; show
# listeners separately and do not claim a remote connection has been tested.
ports=$("${AS_ROOT[@]}" sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | paste -sd, -)
port='<ssh-port>'
if [[ "$ports" =~ ^[0-9]+$ ]]; then
    port=$ports
else
    warn "A single configured SSH port could not be determined (found: ${ports:-unknown}). Replace <ssh-port> after checking the listener."
fi
if command -v ss >/dev/null 2>&1; then
    info 'Current TCP listeners (check the SSH address and port):'
    "${AS_ROOT[@]}" ss -ltnp || warn 'Could not inspect TCP listeners.'
else
    warn 'The ss command is unavailable; check the SSH listening address and port manually.'
fi

current_user=$(id -un)
printf 'Existing SSH username [%s]: ' "$current_user"
if ! IFS= read -r username; then
    error 'Input ended before a username was selected.'
    exit 1
fi
username=${username:-$current_user}
if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || ! id "$username" >/dev/null 2>&1; then
    warn 'Not a verified local account. Replace <username> with an existing SSH login.'
    username='<username>'
fi

printf '\nSuggested commands (not verified): connect from a device that can reach this address:\n'
printf '  ssh -p %s %s@%s\n' "$port" "$username" "$address"
printf '  sftp -P %s %s@%s\n' "$port" "$username" "$address"
warn 'The account must already be allowed to log in; SFTP also requires an enabled SFTP subsystem.'
warn 'The configured port may differ from the active listener. Test from the client and keep your current session open.'
warn 'This does not restrict SSH to the local network. Existing firewall, router, and SSH settings determine exposure.'
if command -v ufw >/dev/null 2>&1; then
    info 'UFW status (no firewall rules were changed):'
    "${AS_ROOT[@]}" ufw status || warn 'Could not inspect UFW status.'
else
    info 'Check host and network firewalls if the connection fails.'
fi
info 'Client isolation, network routing, and VM/container networking may also affect connectivity. DHCP addresses can change.'
