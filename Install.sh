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

# Interactive prompts. ask()/confirm() read from the terminal; ask_secret()
# is used for credentials so tokens are not echoed back to the screen.
ask() {
    # ask "question" "default_value"
    local question="$1"
    local default="${2:-}"
    local answer
    if [[ -n "$default" ]]; then
        if ! read -rp "$(echo -e "${BOLD}${question}${NC} [${default}]: ")" answer; then
            echo "ERROR: input ended while waiting for: $question" >&2
            # ask() usually runs inside $(...): a plain exit would only kill
            # the subshell and EOF retry loops would spin forever.
            kill -TERM $$ 2>/dev/null
            exit 1
        fi
        echo "${answer:-$default}"
    else
        if ! read -rp "$(echo -e "${BOLD}${question}${NC}: ")" answer; then
            echo "ERROR: input ended while waiting for: $question" >&2
            kill -TERM $$ 2>/dev/null
            exit 1
        fi
        echo "$answer"
    fi
}

confirm() {
    # confirm "question" -> returns 0 (yes) or 1 (no)
    local question="$1"
    local answer
    if ! read -rp "$(echo -e "${BOLD}${question}${NC} [y/N]: ")" answer; then
        return 1
    fi
    [[ "$answer" =~ ^([yY][eE][sS]|[yY])$ ]]
}

ask_secret() {
    # ask_secret "prompt" -> prints the secret on stdout, prompt on stderr.
    local prompt="$1" secret
    if ! IFS= read -rsp "${prompt}: " secret; then
        echo "ERROR: input ended while waiting for a secret." >&2
        kill -TERM $$ 2>/dev/null
        exit 1
    fi
    printf '\n' >&2
    printf '%s\n' "$secret"
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
check_sshd_setting() {
    local directive="$1" expected="$2" actual
    if ! sudo sshd -t 2>&1 | tee -a "$LOG_FILE"; then
        error "sshd_config has a syntax error after this change. Fix it before restarting sshd (see $LOG_FILE)."
        return 1
    fi
    actual=$(sudo sshd -T 2>/dev/null | awk -v d="${directive,,}" 'tolower($1)==d {print $2; exit}')
    if [[ -z "$actual" ]]; then
        warn "Could not determine the effective value of $directive (sshd -T). Verify manually after restart."
        return 1
    elif [[ "${actual,,}" != "${expected,,}" ]]; then
        warn "Effective '$directive' is '$actual', not '$expected' as intended. A drop-in file under /etc/ssh/sshd_config.d/*.conf is likely overriding it (Ubuntu/cloud-init default). Edit that file directly or ensure it's included after sshd_config's own settings."
        return 1
    else
        ok "Effective '$directive' confirmed as '$actual'."
    fi
}

# Validates a Linux username before it reaches useradd / /home/<name> paths.
# FIX (Phase 2, F-04): the name was previously taken from interactive input
# unchecked, so values with '/', '..', spaces or a leading '-' could escape
# the intended paths or be parsed as command options. Allowlist matching
# Debian's own username rules instead.
is_valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]] && (( ${#1} <= 32 ))
}

# Validates a tunnel name. The name is used as a path component under
# STATE_DIR/tunnels/<name>/, inside a /tmp mktemp template, and as a
# systemd unit suffix, so it must be a single safe path component.
# FIX (Phase 2, F-04): same unchecked-input problem as the username above.
is_valid_tunnel_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != *".."* && "$1" != -* && "$1" != "." ]]
}

# Asks for a tunnel name until a valid one is entered (see above).
ask_tunnel_name() {
    local name
    while true; do
        name=$(ask "$1" "$2")
        if is_valid_tunnel_name "$name"; then
            printf '%s\n' "$name"
            return 0
        fi
        error "Invalid tunnel name: '$name'. Use letters, digits, '.', '_' or '-' (no '..', no leading '-')." >&2
    done
}

# Backs up /etc/ssh/sshd_config once per run, before the first in-place edit.
# FIX (Phase 2, F-05): sshd_config was previously sed-edited with no backup;
# `sshd -t` validation catches a broken file but there was no one-command
# rollback. Idempotent: only the first call in a run does anything.
backup_sshd_config_once() {
    [[ "${SSHD_BACKUP_DONE:-0}" == "1" ]] && return 0
    [[ -f /etc/ssh/sshd_config ]] || return 0
    local backup
    backup="/etc/ssh/sshd_config.bak-$(date +%Y%m%d-%H%M%S)"
    if sudo cp -a /etc/ssh/sshd_config "$backup" 2>&1 | tee -a "$LOG_FILE"; then
        sudo chmod 600 "$backup" 2>/dev/null || true
        ok "Backup of sshd_config saved to $backup (restore: sudo cp -a $backup /etc/ssh/sshd_config)"
        SSHD_BACKUP_DONE=1
    else
        error "Could not back up /etc/ssh/sshd_config before editing it."
        return 1
    fi
}

# Sets one sshd_config directive (replacing a commented or active line, or
# appending it), after a one-time backup.
apply_sshd_directive() {
    local directive="$1" value="$2"
    if ! backup_sshd_config_once; then
        error "Refusing to edit sshd_config without a backup."
        return 1
    fi
    if sudo grep -q "^#\?${directive}[[:space:]]" /etc/ssh/sshd_config; then
        sudo sed -i "s/^#\?${directive}.*/${directive} ${value}/" /etc/ssh/sshd_config
    else
        echo "${directive} ${value}" | sudo tee -a /etc/ssh/sshd_config > /dev/null
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

    if ! backup_sshd_config_once; then
        error "Refusing to edit sshd_config without a backup."
        return 1
    fi
    if grep -qi '^#\?Subsystem[[:space:]]\+sftp' /etc/ssh/sshd_config 2>/dev/null; then
        if ! sudo sed -i "s|^#\?Subsystem[[:space:]]\+sftp.*|Subsystem sftp ${sftp_server}|" /etc/ssh/sshd_config; then
            error "Could not update the SFTP subsystem in sshd_config."
            return 1
        fi
    else
        if ! echo "Subsystem sftp ${sftp_server}" | sudo tee -a /etc/ssh/sshd_config > /dev/null; then
            error "Could not add the SFTP subsystem to sshd_config."
            return 1
        fi
    fi

    if ! sudo sshd -t 2>&1 | tee -a "$LOG_FILE"; then
        error "sshd_config now has a syntax error after adding the SFTP subsystem - DO NOT restart sshd until this is fixed. See $LOG_FILE."
        return 1
    fi

    if sudo sshd -T 2>/dev/null | grep -qi '^subsystem sftp'; then
        ok "SFTP subsystem configured (${sftp_server})."
    else
        error "Could not confirm SFTP is active after the change. A drop-in file under /etc/ssh/sshd_config.d/*.conf may be interfering. Verify manually: sudo sshd -T | grep -i subsystem"
        return 1
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
    if ! apply_sshd_directive "PasswordAuthentication" "no"; then
        error "Could not update PasswordAuthentication in sshd_config."
        return 1
    fi
    if sudo sshd -t 2>&1 | tee -a "$LOG_FILE"; then
        if ! check_sshd_setting "PasswordAuthentication" "no"; then
            error "PasswordAuthentication could not be confirmed as disabled."
            return 1
        fi
        ok "Password authentication disabled for all accounts."
        if [[ -d /run/systemd/system ]]; then
            warn "Restart sshd to apply changes: sudo systemctl restart ssh"
        else
            warn "Restart sshd to apply changes: sudo pkill sshd && sudo /usr/sbin/sshd"
        fi
    else
        error "sshd_config now has a syntax error - DO NOT restart sshd until this is fixed, or you may lock yourself out. See $LOG_FILE."
        return 1
    fi
}

# The vendor installer puts the fxtunnel binary in ~/.local/bin but only
# arranges for FUTURE shells to have it on PATH (via .bashrc/.profile);
# this already-running shell never sees it, which used to fail the
# post-install check below even after a successful install. Look in the
# known install locations and add the directory to this session's PATH.
# First version-looking line of `fxtunnel --version` (the client may print
# its usage text first, which is not a version).
fx_version() {
    fxtunnel --version 2>&1 | grep -im1 -E 'version|v[0-9]+\.[0-9]+' || echo "version not reported"
}

ensure_fxtunnel_path() {
    command -v fxtunnel &>/dev/null && return 0
    local fx_dir
    for fx_dir in "$HOME/.local/bin" "/usr/local/bin"; do
        if [[ -x "${fx_dir}/fxtunnel" ]]; then
            export PATH="${fx_dir}:${PATH}"
            info "Added ${fx_dir} to PATH for this session (fxtunnel found there)."
            return 0
        fi
    done
    return 1
}

is_valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

is_valid_hostname() {
    is_valid_domain "$1"
}

# Prints a root-owned, non-group/world-writable fxtunnel path safe for a
# root systemd unit. A binary under ~/.local/bin is copied to /usr/local/bin
# first; a root service must never execute a user-writable file.
fx_systemd_bin_path() {
    local src target owner_mode owner mode
    src=$(command -v fxtunnel 2>/dev/null || true)
    [[ -n "$src" ]] || return 1
    target="/usr/local/bin/fxtunnel"
    if [[ "$src" != "$target" ]]; then
        sudo install -d -o root -g root -m 0755 /usr/local/bin || return 1
        sudo install -o root -g root -m 0755 -- "$src" "$target" || return 1
    else
        sudo chown root:root "$target" || return 1
        sudo chmod 0755 "$target" || return 1
    fi
    owner_mode=$(stat -c '%u %a' "$target" 2>/dev/null) || return 1
    IFS=' ' read -r owner mode <<<"$owner_mode"
    [[ "$owner" == "0" ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    printf '%s\n' "$target"
}

create_admin_user() {
    local username pubkey user_home
    while true; do
        username=$(ask "Username for the new admin account" "admin")
        if is_valid_username "$username" && [[ "$username" != "root" ]]; then
            break
        fi
        error "Invalid admin username: '$username'. Use lowercase letters, digits, '_' or '-', starting with a letter or '_', max 32 characters; use the root option for root."
    done

    if id "$username" &>/dev/null; then
        ok "User '$username' already exists."
        user_home=$(getent passwd "$username" 2>/dev/null | cut -d: -f6)
        [[ -n "$user_home" ]] || user_home="/home/$username"
        if ! id -nG "$username" 2>/dev/null | tr ' ' '\n' | grep -qx 'sudo'; then
            info "Adding existing user '$username' to the 'sudo' group."
            if ! sudo usermod -aG sudo "$username" || ! id -nG "$username" 2>/dev/null | tr ' ' '\n' | grep -qx 'sudo'; then
                error "Could not add '$username' to the 'sudo' group."
                return 1
            fi
        fi
    else
        sudo useradd -m -s /bin/bash -G sudo "$username" 2>&1 | tee -a "$LOG_FILE"
        if id "$username" &>/dev/null; then
            ok "User '$username' created and added to the 'sudo' group."
            user_home=$(getent passwd "$username" 2>/dev/null | cut -d: -f6)
            [[ -n "$user_home" ]] || user_home="/home/$username"
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
        if ! add_key_dedup "$pubkey" "${user_home}/.ssh/authorized_keys"; then
            error "Could not add the key for '$username'."
            return 1
        else
            if ! sudo chown -R "${username}:${username}" "${user_home}/.ssh" || \
               ! sudo chmod 700 "${user_home}/.ssh" || \
               ! sudo chmod 600 "${user_home}/.ssh/authorized_keys"; then
                error "The key was written for '$username', but ownership/permissions could not be set; sshd may reject it."
                return 1
            fi
            ok "Key added for '$username'."

            # FIX (High #14 - audit 3): this path was presented as the
            # "recommended" and secure option, but only added a key for the new
            # user - it never touched PasswordAuthentication. Any other local
            # account with a password (including the one running this script)
            # could still log in with a password once the tunnel made sshd
            # publicly reachable, silently undermining the "recommended" label.
            echo
            if confirm "Disable SSH password authentication for ALL accounts now that '$username' has a key? (recommended - do this only after confirming the key works)"; then
                if ! disable_password_auth_confirmed; then
                    error "Password authentication could not be disabled safely."
                    return 1
                fi
            else
                warn "Password authentication left enabled. Any local account with a password can still log in over SSH once the tunnel is public."
            fi
        fi
    else
        warn "No key provided. Set one later (sudo -u $username ssh-import-id ..., or edit /home/$username/.ssh/authorized_keys), or set a password with: sudo passwd $username"
    fi

    state_set user "$username"
}

# Tries to install sudo with the system package manager. This function is
# only called when the script is already running as root, so every attempt is
# best-effort: a failed manager never aborts the script, we simply move on to
# the next one and report at the end if sudo is still missing.
install_sudo_as_root() {
    if command -v apt-get &>/dev/null; then
        info "Trying to install sudo with apt-get ..."
        DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 | tee -a "$LOG_FILE" || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y sudo 2>&1 | tee -a "$LOG_FILE" || true
        command -v sudo &>/dev/null && return 0
    fi
    if command -v apt &>/dev/null; then
        info "Trying to install sudo with apt ..."
        DEBIAN_FRONTEND=noninteractive apt update 2>&1 | tee -a "$LOG_FILE" || true
        DEBIAN_FRONTEND=noninteractive apt install -y sudo 2>&1 | tee -a "$LOG_FILE" || true
        command -v sudo &>/dev/null && return 0
    fi
    if command -v dnf &>/dev/null; then
        info "Trying to install sudo with dnf ..."
        dnf install -y sudo 2>&1 | tee -a "$LOG_FILE" || true
        command -v sudo &>/dev/null && return 0
    fi
    if command -v microdnf &>/dev/null; then
        info "Trying to install sudo with microdnf ..."
        microdnf install -y sudo 2>&1 | tee -a "$LOG_FILE" || true
        command -v sudo &>/dev/null && return 0
    fi
    if command -v yum &>/dev/null; then
        info "Trying to install sudo with yum ..."
        yum install -y sudo 2>&1 | tee -a "$LOG_FILE" || true
        command -v sudo &>/dev/null && return 0
    fi
    if command -v apk &>/dev/null; then
        info "Trying to install sudo with apk ..."
        apk update 2>&1 | tee -a "$LOG_FILE" || true
        apk add --no-cache sudo 2>&1 | tee -a "$LOG_FILE" || true
        command -v sudo &>/dev/null && return 0
    fi
    if command -v pacman &>/dev/null; then
        info "Trying to install sudo with pacman ..."
        # No -Sy here: a partial sync/upgrade can break Arch-based systems.
        pacman -S --noconfirm sudo 2>&1 | tee -a "$LOG_FILE" || true
        command -v sudo &>/dev/null && return 0
    fi
    if command -v zypper &>/dev/null; then
        info "Trying to install sudo with zypper ..."
        zypper --non-interactive refresh 2>&1 | tee -a "$LOG_FILE" || true
        zypper --non-interactive install -y sudo 2>&1 | tee -a "$LOG_FILE" || true
        command -v sudo &>/dev/null && return 0
    fi
    if command -v xbps-install &>/dev/null; then
        info "Trying to install sudo with xbps-install ..."
        xbps-install -Sy sudo 2>&1 | tee -a "$LOG_FILE" || true
        command -v sudo &>/dev/null && return 0
    fi
    return 1
}

# Best-effort sudo bootstrap for minimal VPS images where sudo is absent.
# As root we can install it directly. As a normal user we can try once via
# `su` (which will ask for the root password) and add that user to the sudo
# group. Any failure is reported cleanly; the script never continues without
# a working sudo.
try_install_sudo() {
    command -v sudo &>/dev/null && return 0

    warn "sudo is not installed. Trying to install it automatically ..."

    if [[ "$(id -u)" -eq 0 ]]; then
        install_sudo_as_root || true
        hash -r 2>/dev/null || true
        if command -v sudo &>/dev/null; then
            ok "sudo installed successfully."
            return 0
        fi
    elif command -v su &>/dev/null; then
        warn "sudo is missing and this is not a root shell. Trying once via su (root password required) ..."
        local current_user user_q su_cmd
        current_user=$(id -un)
        printf -v user_q '%q' "$current_user"
        su_cmd="export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive; "
        su_cmd+="if command -v apt-get >/dev/null 2>&1; then apt-get update; apt-get install -y sudo; "
        su_cmd+="elif command -v apt >/dev/null 2>&1; then apt update; apt install -y sudo; "
        su_cmd+="elif command -v dnf >/dev/null 2>&1; then dnf install -y sudo; "
        su_cmd+="elif command -v microdnf >/dev/null 2>&1; then microdnf install -y sudo; "
        su_cmd+="elif command -v yum >/dev/null 2>&1; then yum install -y sudo; "
        su_cmd+="elif command -v apk >/dev/null 2>&1; then apk update; apk add --no-cache sudo; "
        su_cmd+="elif command -v pacman >/dev/null 2>&1; then pacman -S --noconfirm sudo; "
        su_cmd+="elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive refresh; zypper --non-interactive install -y sudo; "
        su_cmd+="elif command -v xbps-install >/dev/null 2>&1; then xbps-install -Sy sudo; fi; "
        su_cmd+="if getent group sudo >/dev/null 2>&1; then usermod -aG sudo ${user_q} 2>/dev/null || adduser ${user_q} sudo 2>/dev/null || true; fi"
        if su -c "$su_cmd"; then
            hash -r 2>/dev/null || true
            if command -v sudo &>/dev/null; then
                ok "sudo installed successfully."
                return 0
            fi
        fi
    fi

    return 1
}

require_root_tools() {
    if ! command -v sudo &>/dev/null; then
        if ! try_install_sudo; then
            error "sudo is not available on this system and could not be installed automatically."
            error "Install it manually, then re-run this script. Examples: 'apt-get install -y sudo' (Debian/Ubuntu, as root), 'dnf install -y sudo' (Fedora/RHEL), or 'apk add sudo' (Alpine)."
            exit 1
        fi
    fi
    # FIX (Medium #9): the original script only checked that the `sudo`
    # binary existed, not that the current user can actually use it. This
    # caused late, confusing failures deep into the script instead of a
    # clear failure up front.
    if ! sudo -v 2>/dev/null; then
        error "The current user does not appear to have sudo privileges (or the sudo password was refused)."
        error "If your account was just added to the sudo group, disconnect/reconnect your SSH session and re-run this script."
        exit 1
    fi
}


install_cloudflared_github_verified() {
    local ARCH ASSET_NAME CF_VERSION URL TMP_DEB EXPECTED_SHA ACTUAL_SHA CF_RELEASE_API
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
        if [[ -n "$CF_VERSION" ]] && [[ ! "$CF_VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
            error "Invalid cloudflared version: '$CF_VERSION'."
            return 1
        fi
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
                    return 1
                fi
            else
                error "No published checksum available via the GitHub API for this asset (rate limit, network issue, or API change). Refusing to install an unverified package as root."
                rm -f "$TMP_DEB"
                return 1
            fi

            sudo dpkg -i "$TMP_DEB" 2>&1 | tee -a "$LOG_FILE"
            # Resolve any missing dependencies
            sudo apt-get install -f -y 2>&1 | tee -a "$LOG_FILE"
            rm -f "$TMP_DEB"
        else
            error "Failed to download cloudflared. Check your network connection."
            rm -f "$TMP_DEB"
            return 1
        fi
    command -v cloudflared &>/dev/null
}

apt_update() {
    sudo apt-get update 2>&1 | tee -a "$LOG_FILE"
}

apt_install() {
    sudo apt-get install -y "$@" 2>&1 | tee -a "$LOG_FILE"
}

install_nodejs_nodesource() {
    local major=$1 tmp_script
    tmp_script=$(mktemp "/tmp/nodesource-setup-XXXXXX.sh") || return 1
    info "Downloading the NodeSource setup script for Node.js ${major}.x ..."
    if ! curl -fsSL "https://deb.nodesource.com/setup_${major}.x" -o "$tmp_script" 2>&1 | tee -a "$LOG_FILE"; then
        rm -f "$tmp_script"
        return 1
    fi
    if ! sudo -E bash "$tmp_script" 2>&1 | tee -a "$LOG_FILE"; then
        rm -f "$tmp_script"
        return 1
    fi
    rm -f "$tmp_script"
    apt_install nodejs || return 1
    command -v node &>/dev/null && command -v npm &>/dev/null
}

install_cloudflared_official_repo() {
    if command -v cloudflared &>/dev/null; then
        ok "cloudflared is already installed ($(cloudflared --version 2>&1 | head -1))."
        return 0
    fi
    apt_install curl gnupg ca-certificates apt-transport-https || return 1
    sudo install -d -m 0755 /usr/share/keyrings || return 1
    info "Adding the official Cloudflare apt repository ..."
    if ! curl -fsSL "https://pkg.cloudflare.com/cloudflare-main.gpg" | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/cloudflare-main.gpg 2>&1 | tee -a "$LOG_FILE"; then
        return 1
    fi
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null || return 1
    apt_update || return 1
    apt_install cloudflared || return 1
    command -v cloudflared &>/dev/null
}

install_cloudflared_best_effort() {
    if command -v cloudflared &>/dev/null; then
        ok "cloudflared is already installed ($(cloudflared --version 2>&1 | head -1))."
        return 0
    fi
    info "Trying the official Cloudflare apt repository first ..."
    if install_cloudflared_official_repo; then
        ok "cloudflared installed from the official Cloudflare repository."
        return 0
    fi
    warn "The official Cloudflare repository method failed. Falling back to the verified GitHub .deb ..."
    if install_cloudflared_github_verified; then
        ok "cloudflared installed from the verified GitHub release package."
        return 0
    fi
    return 1
}

# Optional VPS essentials pack (dedicated menu entry, also proposed during
# Full setup). Best-effort by design: one failing component is logged and
# counted, the remaining components are still attempted, and the caller
# decides whether the failure is fatal (dedicated menu entry) or just a
# warning (Full setup continues with SSH + tunnel).
install_essentials() {
    local failures=0 node_choice

    if ! command -v apt-get &>/dev/null; then
        error "The essentials pack is apt-based and needs apt-get (Ubuntu/Debian)."
        return 1
    fi

    title "Installing essential VPS tools"
    apt_update || failures=$((failures + 1))

    info "Installing base/build/admin packages ..."
    apt_install build-essential curl wget git vim nano unzip zip         ca-certificates gnupg apt-transport-https sudo tmux screen         htop net-tools ufw fail2ban rsync jq dnsutils lsof         || failures=$((failures + 1))

    info "Installing Python tooling ..."
    apt_update || failures=$((failures + 1))
    apt_install python3 python3-venv python3-pip || failures=$((failures + 1))

    while true; do
        node_choice=$(ask "Node.js major version to install (20 LTS or 22)" "20")
        case "$node_choice" in
            20|22) break ;;
            *) error "Invalid Node.js version: '$node_choice'. Enter 20 or 22." ;;
        esac
    done
    if install_nodejs_nodesource "$node_choice"; then
        ok "Node.js $(node --version 2>/dev/null) / npm $(npm --version 2>/dev/null) installed."
    else
        warn "NodeSource setup failed; falling back to the distribution nodejs/npm packages ..."
        apt_install nodejs npm || failures=$((failures + 1))
    fi
    if command -v npm &>/dev/null; then
        info "Installing pm2 globally ..."
        sudo npm install -g pm2 2>&1 | tee -a "$LOG_FILE" || failures=$((failures + 1))
    else
        warn "npm is not available; skipping pm2."
        failures=$((failures + 1))
    fi

    if ! install_cloudflared_best_effort; then
        warn "cloudflared could not be installed by either method (official repo or verified GitHub .deb)."
        failures=$((failures + 1))
    fi

    apt_update || failures=$((failures + 1))

    if [[ "$failures" -gt 0 ]]; then
        warn "Essentials finished with $failures failed component(s). Other components were still attempted; see the log: $LOG_FILE"
        return 1
    fi
    ok "Essential VPS tools installed."
    return 0
}

# FIX (Medium #15 - audit 3): a predictable filename under the shared,
# world-writable /tmp is a symlink/TOCTOU risk (a local attacker could
# pre-create the path before this script runs). mktemp allocates the file
# atomically with a unique name and 0600 permissions.
# --help: print usage and exit before creating any log/state.
usage() {
    cat <<'USAGE'
setup-ssh-tunnel.sh — OpenSSH server + Cloudflare Tunnel / fxTunnel (SSH access via a domain)

Usage:
  ./Install.sh           Interactive menu (recommended)
  ./Install.sh --help    This text

Menu:
  1) Full setup (SSH + tunnel client + tunnel + DNS route + run)
  2) Install OpenSSH server only
  3) Install the tunnel client only (cloudflared or fxTunnel)
  4) Create / configure a tunnel
  5) Run an already configured tunnel (pick from saved tunnels)
  6) Manage tunnels (status / logs / stop / restart)
  7) Install essential VPS tools (build tools, Python, Node.js, pm2, cloudflared, admin utilities)
  8) Quit

State and saved tunnels live in ~/.setup-ssh-tunnel/ (permissions 700/600).
Before the first change in a run, /etc/ssh/sshd_config is backed up to
/etc/ssh/sshd_config.bak-<timestamp>.
USAGE
}
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

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

# Lists tunnels saved under STATE_DIR/tunnels (one name per line).
list_saved_tunnels() {
    local d
    [[ -d "${STATE_DIR}/tunnels" ]] || return 0
    for d in "${STATE_DIR}/tunnels"/*/; do
        [[ -d "$d" ]] || continue
        basename "$d"
    done
}

# Echoes the chosen saved tunnel name; prompts/lists go to stderr so the
# result stays clean in $(...). Enter selects the last used tunnel.
choose_saved_tunnel() {
    local -a tunnels=()
    mapfile -t tunnels < <(list_saved_tunnels)
    ((${#tunnels[@]} > 0)) || return 1
    if ((${#tunnels[@]} == 1)); then
        printf '%s\n' "${tunnels[0]}"
        return 0
    fi
    local i choice last
    last=$(last_tunnel_used)
    {
        echo "Saved tunnels:"
        for i in "${!tunnels[@]}"; do
            printf '  %d) %s\n' "$((i + 1))" "${tunnels[$i]}"
        done
    } >&2
    while true; do
        choice=$(ask "Tunnel number (Enter = last used: ${last:-none})" "")
        if [[ -z "$choice" && -n "$last" ]]; then
            printf '%s\n' "$last"
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#tunnels[@]})); then
            printf '%s\n' "${tunnels[$((10#$choice - 1))]}"
            return 0
        fi
        error "Invalid selection: '$choice'." >&2
    done
}

# A saved PID can outlive a reboot and be reused by an unrelated process.
# Only trust it when the live process really is a tunnel client.
tunnel_pid_is_tunnel() {
    local pid="$1" cmdline
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    [[ "$cmdline" == *cloudflared* || "$cmdline" == *fxtunnel* ]]
}

# Prints the runtime status of a saved tunnel.
tunnel_runtime_status() {
    local name="$1" svc pid
    svc=$(tunnel_state_get "$name" service)
    if [[ -n "$svc" ]] && command -v systemctl &>/dev/null && systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "running (systemd: $svc)"
        return
    fi
    pid=$(tunnel_state_get "$name" pid)
    if [[ -n "$pid" ]] && tunnel_pid_is_tunnel "$pid"; then
        echo "running (background, PID $pid)"
        return
    fi
    echo "not running"
}

# Menu 6: inspect a saved tunnel, view logs, stop or restart it.
manage_tunnels() {
    title "Manage tunnels"

    local -a tunnels=()
    mapfile -t tunnels < <(list_saved_tunnels)
    if ((${#tunnels[@]} == 0)); then
        warn "No saved tunnels found under ${STATE_DIR}/tunnels."
        return 0
    fi

    local name
    name=$(choose_saved_tunnel) || return 0
    if ! is_valid_tunnel_name "$name"; then
        error "Invalid saved tunnel name: '$name'."
        return 1
    fi

    local token host svc pid port log
    token=$(tunnel_state_get "$name" token)
    host=$(tunnel_state_get "$name" hostname)
    svc=$(tunnel_state_get "$name" service)
    pid=$(tunnel_state_get "$name" pid)
    port=$(tunnel_state_get "$name" port)
    log=$(tunnel_state_get "$name" log)

    echo
    echo "  Tunnel  : $name"
    if [[ -n "$token" ]]; then
        echo "  Provider: fxtunnel"
    else
        echo "  Provider: cloudflared"
    fi
    [[ -n "$host" ]] && echo "  Hostname: $host"
    [[ -n "$port" ]] && echo "  Port    : $port"
    echo "  Status  : $(tunnel_runtime_status "$name")"
    echo
    echo "  1) View logs"
    echo "  2) Stop tunnel"
    echo "  3) Restart tunnel"
    echo "  4) Back"
    local action
    action=$(ask "Action (1-4)" "4")

    case "$action" in
        1)
            if [[ -n "$log" && -f "$log" ]]; then
                tail -n 50 -- "$log"
            elif [[ -n "$svc" ]] && command -v systemctl &>/dev/null; then
                sudo journalctl -u "$svc" -n 50 --no-pager 2>/dev/null || warn "No journal entries found for $svc."
            else
                warn "No log file recorded for '$name'."
            fi
            ;;
        2)
            if confirm "Stop tunnel '$name'?"; then
                if [[ -n "$svc" ]] && command -v systemctl &>/dev/null && systemctl is-active --quiet "$svc" 2>/dev/null; then
                    sudo systemctl stop "$svc" 2>&1 | tee -a "$LOG_FILE" && ok "Service $svc stopped."
                fi
                if [[ -n "$pid" ]] && tunnel_pid_is_tunnel "$pid"; then
                    kill "$pid" 2>/dev/null && ok "Background tunnel (PID $pid) stopped."
                    rm -f -- "${STATE_DIR}/tunnels/$name/pid"
                elif [[ -n "$pid" ]]; then
                    warn "Saved PID $pid is not a tunnel process (stale or reused); it was NOT killed."
                    rm -f -- "${STATE_DIR}/tunnels/$name/pid"
                fi
                info "Status now: $(tunnel_runtime_status "$name")"
            fi
            ;;
        3)
            if [[ -n "$svc" ]] && command -v systemctl &>/dev/null; then
                sudo systemctl restart "$svc" 2>&1 | tee -a "$LOG_FILE" && ok "Service $svc restarted."
            elif [[ -n "$port" ]]; then
                if [[ -n "$pid" ]] && tunnel_pid_is_tunnel "$pid"; then
                    kill "$pid" 2>/dev/null
                fi
                sleep 1
                local new_log
                new_log=$(mktemp "/tmp/tunnel-${name}-XXXXXX.log")
                if [[ -n "$token" ]]; then
                    ensure_fxtunnel_path || true
                    FXTUNNEL_TOKEN="$token" nohup fxtunnel tcp "$port" > "$new_log" 2>&1 &
                else
                    nohup cloudflared tunnel run --url "ssh://localhost:${port}" "$name" > "$new_log" 2>&1 &
                fi
                local new_pid=$!
                sleep 2
                if kill -0 "$new_pid" 2>/dev/null; then
                    tunnel_state_set "$name" pid "$new_pid"
                    tunnel_state_set "$name" log "$new_log"
                    ok "Tunnel '$name' restarted in the background (PID $new_pid). Logs: $new_log"
                else
                    error "Tunnel '$name' failed to restart. Check: $new_log"
                fi
            else
                warn "Cannot restart '$name' automatically (no systemd service or saved port). Use menu option 5 instead."
            fi
            ;;
        *)
            ;;
    esac
}

banner
info "Command details will also be logged to: $LOG_FILE"

# ---------------------------------------------------------------------------
# Step 0: Pre-flight checks
# ---------------------------------------------------------------------------
title "Pre-flight checks"

require_root_tools

if [[ -f /etc/os-release ]]; then
    # /etc/os-release is a trusted runtime file provided by the OS.
    # shellcheck disable=SC1091
    . /etc/os-release
    info "Detected system: ${PRETTY_NAME:-unknown Linux}"
    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        warn "This script targets Ubuntu/Debian. Your system (${PRETTY_NAME:-unknown Linux}) might not be compatible."
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
echo "  6) Manage tunnels (status / logs / stop / restart)"
echo "  7) Install essential VPS tools"
echo "  8) Quit"
echo

MODE=$(ask "Choice (1-8)" "1")

case "$MODE" in
    1) DO_FULL=1; DO_SSH=1; DO_INSTALL_CF=1; DO_CREATE_TUNNEL=1; DO_ROUTE_DNS=1; DO_RUN=1; DO_MANAGE=0; DO_ESSENTIALS=0 ;;
    2) DO_FULL=0; DO_SSH=1; DO_INSTALL_CF=0; DO_CREATE_TUNNEL=0; DO_ROUTE_DNS=0; DO_RUN=0; DO_MANAGE=0; DO_ESSENTIALS=0 ;;
    3) DO_FULL=0; DO_SSH=0; DO_INSTALL_CF=1; DO_CREATE_TUNNEL=0; DO_ROUTE_DNS=0; DO_RUN=0; DO_MANAGE=0; DO_ESSENTIALS=0 ;;
    4) DO_FULL=0; DO_SSH=0; DO_INSTALL_CF=0; DO_CREATE_TUNNEL=1; DO_ROUTE_DNS=1; DO_RUN=0; DO_MANAGE=0; DO_ESSENTIALS=0 ;;
    5) DO_FULL=0; DO_SSH=0; DO_INSTALL_CF=0; DO_CREATE_TUNNEL=0; DO_ROUTE_DNS=0; DO_RUN=1; DO_MANAGE=0; DO_ESSENTIALS=0 ;;
    6) DO_FULL=0; DO_SSH=0; DO_INSTALL_CF=0; DO_CREATE_TUNNEL=0; DO_ROUTE_DNS=0; DO_RUN=0; DO_MANAGE=1; DO_ESSENTIALS=0 ;;
    7) DO_FULL=0; DO_SSH=0; DO_INSTALL_CF=0; DO_CREATE_TUNNEL=0; DO_ROUTE_DNS=0; DO_RUN=0; DO_MANAGE=0; DO_ESSENTIALS=1 ;;
    8) info "See you next time."; exit 0 ;;
    *) error "Invalid choice."; exit 1 ;;
esac


# ---------------------------------------------------------------------------
# Optional step: essential VPS tools (menu 7 = dedicated, Full setup = opt-in)
# ---------------------------------------------------------------------------
if [[ "$DO_ESSENTIALS" -eq 1 ]]; then
    if install_essentials; then
        ok "Essential tools setup complete. Full log available at: $LOG_FILE"
        exit 0
    fi
    error "Essential tools setup finished with failures. Full log available at: $LOG_FILE"
    exit 1
fi

if [[ "$DO_FULL" -eq 1 ]] && confirm "Install the essential VPS tools pack too (build tools, Python, Node.js 20/22 + pm2, cloudflared, admin utilities)?"; then
    if ! install_essentials; then
        warn "The essentials pack reported failures. Continuing with the SSH + tunnel setup; you can re-run menu option 7 later. See the log: $LOG_FILE"
    fi
fi

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

    SSH_RUNNING=0
    if [[ -d /run/systemd/system ]]; then
        if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
            SSH_RUNNING=1
        fi
    fi
    if pgrep -x sshd &>/dev/null; then
        SSH_RUNNING=1
    fi
    if [[ "$SSH_RUNNING" -eq 0 ]]; then
        error "sshd does not appear to be running after the start attempt. Fix the SSH service before continuing."
        exit 1
    fi
    ok "sshd is running."

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
            if ! create_admin_user; then
                error "Admin user configuration failed. Stopping instead of continuing with unconfigured SSH access."
                exit 1
            fi
            ;;
        2)
            if confirm "Are you sure you want to enable root SSH access? A dedicated user (option 1) is safer."; then
                if confirm "Do you want to set/change the root password now?"; then
                    if ! sudo passwd root; then
                        error "Failed to set the root password; root SSH settings were not changed."
                    elif confirm "Allow root to log in WITH THIS PASSWORD over SSH? (sets PermitRootLogin yes - without this, the password only works locally)"; then
                        if ! apply_sshd_directive "PermitRootLogin" "yes"; then error "Failed to set PermitRootLogin; stopping."; exit 1; fi
                        warn "PermitRootLogin set to 'yes'. Root + password over a public tunnel is a significant exposure; consider adding a key and disabling password auth below."
                        if ! check_sshd_setting "PermitRootLogin" "yes"; then error "PermitRootLogin could not be confirmed as 'yes'; stopping."; exit 1; fi
                    else
                        if ! apply_sshd_directive "PermitRootLogin" "prohibit-password"; then error "Failed to set PermitRootLogin; stopping."; exit 1; fi
                        info "PermitRootLogin left as 'prohibit-password': the root password will work locally (console) but NOT over SSH. Add a key below, or use option 1."
                        if ! check_sshd_setting "PermitRootLogin" "prohibit-password"; then error "PermitRootLogin could not be confirmed; stopping."; exit 1; fi
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
                            if ! apply_sshd_directive "PermitRootLogin" "prohibit-password"; then error "Failed to set PermitRootLogin for root; stopping."; exit 1; fi
                            ok "Key added for root (PermitRootLogin set to 'prohibit-password': key-only)."
                            if ! check_sshd_setting "PermitRootLogin" "prohibit-password"; then error "PermitRootLogin could not be confirmed for root; stopping."; exit 1; fi
                            if confirm "Disable password login entirely now that a key is configured? (recommended)"; then
                                if ! apply_sshd_directive "PasswordAuthentication" "no"; then error "Failed to disable password authentication; stopping."; exit 1; fi
                                ok "Password authentication disabled."
                                if ! check_sshd_setting "PasswordAuthentication" "no"; then error "PasswordAuthentication could not be confirmed as disabled; stopping."; exit 1; fi
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
        3)
            info "User/access configuration skipped."
            ;;
        *)
            error "Invalid access choice: '$ACCESS_MODE'."
            exit 1
            ;;
    esac

    echo
    if ! ensure_sftp_enabled; then
        error "SFTP configuration failed. Stopping before the SSH step is reported complete."
        exit 1
    fi

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
        fxtunnel|2) TUNNEL_PROVIDER="fxtunnel" ;;
        *) TUNNEL_PROVIDER="cloudflared" ;;
    esac
    # Remembered so later steps (run) know which provider was set up in
    # this session even if invoked as a separate menu choice.
    state_set provider "$TUNNEL_PROVIDER"

if [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
    title "Installing fxTunnel"

    ensure_fxtunnel_path || true
    if command -v fxtunnel &>/dev/null; then
        ok "fxTunnel is already installed ($(fx_version))."
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
        # release asset, so it has no published checksum. Never execute it
        # unless the user supplies an expected SHA-256 obtained from a
        # trusted source and the downloaded file matches it.
        warn "No published checksum is available for the install.sh script itself (only release binaries have checksums.txt)."
        FX_INSTALLER_SHA256=$(ask "SHA-256 of fxtun.dev/install.sh from a trusted source (leave empty to abort)" "${FX_INSTALLER_SHA256:-}")
        FX_INSTALLER_SHA256="${FX_INSTALLER_SHA256,,}"
        if [[ ! "$FX_INSTALLER_SHA256" =~ ^[a-f0-9]{64}$ ]]; then
            error "A trusted SHA-256 is required before this installer script can be executed. Aborting."
            rm -f "$FX_INSTALLER_TMP"
            exit 1
        fi
        FX_INSTALLER_ACTUAL_SHA=$(sha256sum "$FX_INSTALLER_TMP" | awk '{print $1}')
        if [[ "$FX_INSTALLER_ACTUAL_SHA" != "$FX_INSTALLER_SHA256" ]]; then
            error "fxTunnel installer checksum mismatch (expected $FX_INSTALLER_SHA256, got $FX_INSTALLER_ACTUAL_SHA). Aborting."
            rm -f "$FX_INSTALLER_TMP"
            exit 1
        fi
        ok "fxTunnel installer checksum verified (sha256)."

        if sh "$FX_INSTALLER_TMP" 2>&1 | tee -a "$LOG_FILE"; then
            ok "fxTunnel installer completed."
        else
            error "fxTunnel installer exited with an error. Check the log: $LOG_FILE"
            rm -f "$FX_INSTALLER_TMP"
            exit 1
        fi
        rm -f "$FX_INSTALLER_TMP"
    fi

    ensure_fxtunnel_path || true
    if command -v fxtunnel &>/dev/null; then
        ok "fxTunnel installed: $(fx_version)"
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
        if ! install_cloudflared_github_verified; then
            error "cloudflared installation failed. Check the log: $LOG_FILE"
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
                fxtunnel|2) TUNNEL_PROVIDER="fxtunnel" ;;
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
        if [[ -z "$FX_TOKEN" ]]; then
            FX_TOKEN=$(ask_secret "fxTunnel token (starts with sk_)")
        fi
        if [[ -z "$FX_TOKEN" ]]; then
            error "A token is required to use fxTunnel."
        elif [[ "$FX_TOKEN" =~ ^sk_[A-Za-z0-9][A-Za-z0-9._~+/=-]*$ ]]; then
            break
        else
            error "Invalid fxTunnel token format (expected 'sk_' followed by letters, digits, '.', '_', '-', '~', '+', '/' or '=')."
            FX_TOKEN=""
        fi
    done

    TUNNEL_NAME=$(ask_tunnel_name "Name to identify this tunnel locally (used only for this script's own bookkeeping)" "ssh-sandbox")

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

    TUNNEL_NAME=$(ask_tunnel_name "Name of the tunnel to create (or existing one to reuse)" "ssh-sandbox")

    EXISTING_ID=$(get_tunnel_id "$TUNNEL_NAME")

    if [[ -n "$EXISTING_ID" ]]; then
        warn "A tunnel named '$TUNNEL_NAME' already exists (ID: $EXISTING_ID)."
        if confirm "Reuse it?"; then
            TUNNEL_ID="$EXISTING_ID"
        else
            TUNNEL_NAME=$(ask_tunnel_name "New tunnel name" "${TUNNEL_NAME}-2")
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
        if is_valid_domain "$DOMAIN"; then
            break
        fi
        error "Invalid domain: '$DOMAIN'. Enter a domain such as jcversanb.dpdns.org."
    done

    SUBDOMAIN=$(ask "Subdomain name to use (e.g. ssh)" "ssh")
    while [[ -n "$SUBDOMAIN" ]] && [[ ! "$SUBDOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; do
        error "Invalid subdomain: '$SUBDOMAIN'. Use DNS labels such as 'ssh' or 'ssh.internal'."
        SUBDOMAIN=$(ask "Subdomain name to use (e.g. ssh)" "ssh")
    done

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
        while true; do
            SSH_HOSTNAME=$(ask "Enter the full hostname you want directly" "$SSH_HOSTNAME")
            if is_valid_hostname "$SSH_HOSTNAME"; then
                break
            fi
            error "Invalid hostname: '$SSH_HOSTNAME'."
        done
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
TUNNEL_START_FAILED=0
# ---------------------------------------------------------------------------
if [[ "$DO_RUN" -eq 1 ]]; then
    title "Running the tunnel"

    if [[ -z "${TUNNEL_NAME:-}" ]]; then
        if TUNNEL_NAME=$(choose_saved_tunnel); then
            info "Selected tunnel: $TUNNEL_NAME"
        else
            TUNNEL_NAME=$(ask_tunnel_name "Name of the tunnel to run" "ssh-sandbox")
        fi
    fi

    # Names loaded from saved state never passed the input validation
    # above; reject anything unsafe before it reaches a file path.
    if ! is_valid_tunnel_name "${TUNNEL_NAME:-}"; then
        error "Invalid tunnel name: '${TUNNEL_NAME:-}'. Use letters, digits, '.', '_' or '-' (no '..', no leading '-')."
        exit 1
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
    while [[ -z "${LOCAL_PORT:-}" ]]; do
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
        if [[ ! "$RUN_MODE" =~ ^[123]$ ]]; then
            error "Invalid run mode: '$RUN_MODE'. Choose 1, 2 or 3."
            exit 1
        fi
    else
        warn "systemd not available here: option 3 won't work on this system."
        RUN_MODE=$(ask "Run mode (1-2)" "2")
        if [[ ! "$RUN_MODE" =~ ^[12]$ ]]; then
            error "Invalid run mode: '$RUN_MODE'. Choose 1 or 2."
            exit 1
        fi
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
        # FIX (Phase 2, F-06): the token used to be passed as '-t <token>'
        # in argv, visible to every local user in `ps aux` for the whole
        # life of the tunnel. The client reads FXTUNNEL_TOKEN from its
        # environment instead (vendor-documented), so keep it out of argv.
        ensure_fxtunnel_path || true
        CMD_ARR=(fxtunnel tcp "${LOCAL_PORT}")
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
            if ! sudo mkdir -p /etc/cloudflared; then
                error "Could not create /etc/cloudflared. Falling back to background mode."
                RUN_MODE=2
            elif ! printf 'tunnel: %s\ncredentials-file: %s\nurl: ssh://localhost:%s\n' "$TUNNEL_ID" "$CRED_FILE" "$LOCAL_PORT" | sudo tee /etc/cloudflared/config.yml > /dev/null; then
                error "Could not write /etc/cloudflared/config.yml. Falling back to background mode."
                RUN_MODE=2
            elif sudo cloudflared service install 2>&1 | tee -a "$LOG_FILE" && \
               sudo systemctl enable --now cloudflared 2>&1 | tee -a "$LOG_FILE"; then
                sleep 2
                if systemctl is-active --quiet cloudflared; then
                    tunnel_state_set "$TUNNEL_NAME" service "cloudflared"
                    tunnel_state_set "$TUNNEL_NAME" port "$LOCAL_PORT"
                    ok "cloudflared installed and running as a systemd service."
                    info "Manage it with: sudo systemctl {status|restart|stop} cloudflared"
                    info "Logs: sudo journalctl -u cloudflared -f"
                else
                    error "The cloudflared service does not look active. Check: sudo journalctl -u cloudflared -e"
                    TUNNEL_START_FAILED=1
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
        # passed only via an Environment= line in a root-only-readable
        # unit file; the client reads FXTUNNEL_TOKEN itself, so the token
        # never appears in ExecStart / argv either (FIX Phase 2, F-06).
        UNIT_NAME="fxtunnel-${TUNNEL_NAME}"
        UNIT_FILE="/etc/systemd/system/${UNIT_NAME}.service"
        if ! FXTUNNEL_BIN_PATH=$(fx_systemd_bin_path); then
            error "Could not prepare a root-owned fxtunnel binary under /usr/local/bin. Cannot install the systemd service safely."
            warn "Falling back to background mode."
            RUN_MODE=2
        else
            info "Writing ${UNIT_FILE} ..."
            if ! sudo install -m 600 /dev/null "$UNIT_FILE"; then
                error "Could not create ${UNIT_FILE}. Falling back to background mode."
                RUN_MODE=2
            elif ! printf '%s\n' \
                '[Unit]' \
                "Description=fxTunnel (${TUNNEL_NAME}) - TCP tunnel for local port ${LOCAL_PORT}" \
                'After=network-online.target' \
                'Wants=network-online.target' \
                '' \
                '[Service]' \
                'Type=simple' \
                "Environment=FXTUNNEL_TOKEN=${FX_TOKEN}" \
                "ExecStart=${FXTUNNEL_BIN_PATH} tcp ${LOCAL_PORT}" \
                'Restart=on-failure' \
                'RestartSec=5' \
                '' \
                '[Install]' \
                'WantedBy=multi-user.target' \
                | sudo tee "$UNIT_FILE" > /dev/null; then
                error "Could not write ${UNIT_FILE}. Falling back to background mode."
                RUN_MODE=2
            elif ! sudo chmod 600 "$UNIT_FILE"; then
                error "Could not set permissions on ${UNIT_FILE}. Falling back to background mode."
                RUN_MODE=2
            elif sudo systemctl daemon-reload 2>&1 | tee -a "$LOG_FILE" && \
               sudo systemctl enable --now "$UNIT_NAME" 2>&1 | tee -a "$LOG_FILE"; then
                sleep 2
                if systemctl is-active --quiet "$UNIT_NAME"; then
                    tunnel_state_set "$TUNNEL_NAME" service "$UNIT_NAME"
                    tunnel_state_set "$TUNNEL_NAME" port "$LOCAL_PORT"
                    ok "fxTunnel installed and running as a systemd service ($UNIT_NAME)."
                    info "Manage it with: sudo systemctl {status|restart|stop} $UNIT_NAME"
                    info "Logs: sudo journalctl -u $UNIT_NAME -f"
                else
                    error "The $UNIT_NAME service does not look active. Check: sudo journalctl -u $UNIT_NAME -e"
                    TUNNEL_START_FAILED=1
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
            info "Command: FXTUNNEL_TOKEN=<hidden> fxtunnel tcp ${LOCAL_PORT}"
            FXTUNNEL_TOKEN="$FX_TOKEN" "${CMD_ARR[@]}"
        else
            info "Command: ${CMD_ARR[*]}"
            "${CMD_ARR[@]}"
        fi
    elif [[ "$RUN_MODE" == "2" ]]; then
        NOHUP_LOG=$(mktemp "/tmp/${SERVICE_LABEL}-${TUNNEL_NAME}-XXXXXX.log")
        info "Running in the background. Logs: $NOHUP_LOG"
        if [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
            FXTUNNEL_TOKEN="$FX_TOKEN" nohup "${CMD_ARR[@]}" > "$NOHUP_LOG" 2>&1 &
        else
            nohup "${CMD_ARR[@]}" > "$NOHUP_LOG" 2>&1 &
        fi
        TUNNEL_PID=$!
        sleep 3
        if kill -0 "$TUNNEL_PID" 2>/dev/null; then
            ok "Tunnel running in the background (PID: $TUNNEL_PID)."
            # FIX (Medium #8): the PID used to only be printed to the
            # terminal, with no way to retrieve it in a later session.
            tunnel_state_set "$TUNNEL_NAME" pid "$TUNNEL_PID"
            tunnel_state_set "$TUNNEL_NAME" log "$NOHUP_LOG"
            tunnel_state_set "$TUNNEL_NAME" port "$LOCAL_PORT"
            info "To stop it later: kill \$(cat \"${STATE_DIR}/tunnels/${TUNNEL_NAME}/pid\")"
            info "To view the logs: tail -f $NOHUP_LOG"
            if [[ "$TUNNEL_PROVIDER" == "fxtunnel" ]]; then
                info "fxTunnel prints the assigned public host:port to this log on startup - check it to get your connection details."
            fi
        else
            error "The tunnel appears to have failed to start. Check: $NOHUP_LOG"
            TUNNEL_START_FAILED=1
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Step 7: Manage saved tunnels (terminal action - no summary afterwards)
# ---------------------------------------------------------------------------
if [[ "$DO_MANAGE" -eq 1 ]]; then
    manage_tunnels
    exit 0
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
    echo -e "${GREEN}fxTunnel (SaaS) does not assign a fixed hostname.${NC}"
    echo "The public host and port are printed by the fxtunnel client itself when the"
    echo "tunnel starts - check the foreground output, the background log shown above,"
    echo "or 'sudo journalctl -u fxtunnel-<name> -f' if installed as a systemd service."
    echo
    echo "Once you have that host:port, connect with:"
    echo -e "     ${BOLD}ssh -p <port> ${CONNECT_USER}@<host>${NC}"
    echo
    warn "Reminder: this port is reachable by anyone on the internet who knows it."
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

if [[ "${TUNNEL_START_FAILED:-0}" -eq 1 ]]; then
    error "Tunnel failed to start. See the log above for details."
    exit 1
fi

ok "Done. Full log available at: $LOG_FILE"
