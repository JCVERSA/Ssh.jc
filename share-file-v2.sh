#!/usr/bin/env bash
#
# share-file.sh v2
#
# Temporary public file sharing:
#   folder -> ZIP -> localhost Python HTTP -> Cloudflare Quick Tunnel
#
# Usage:
#   ./share-file-v2.sh /path/to/folder
#
# Design goals:
#   - never modify the source directory
#   - expose only the generated ZIP, never the source tree
#   - isolate Cloudflare config from any existing ~/.cloudflared/config.yaml
#   - verify ZIP integrity
#   - verify the local HTTP endpoint
#   - attempt a real public HTTPS HEAD check
#   - clean up child processes and temporary files on exit
#   - install missing dependencies when a supported package manager is available
#

set -Eeuo pipefail

readonly SCRIPT_VERSION="2.0.0"
readonly CF_API="https://api.github.com/repos/cloudflare/cloudflared/releases/latest"
readonly CF_DOWNLOAD_BASE="https://github.com/cloudflare/cloudflared/releases/download"
readonly PORT_FIRST=18080
readonly PORT_LAST=18180

SOURCE_DIR=""
SOURCE_NAME=""
ZIP_NAME=""
ZIP_PATH=""
WORK_DIR=""
SERVE_DIR=""
CF_HOME=""
PORT=""
PUBLIC_URL=""
CLOUDFLARED_BIN=""
SERVER_PID=""
TUNNEL_PID=""
CLEANED_UP=0
SUDO=""

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok_msg() { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn_msg() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
error_msg() { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; }
die() { error_msg "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    local rc=$?

    if (( CLEANED_UP )); then
        return
    fi
    CLEANED_UP=1

    set +e

    printf '\n'
    info "Stopping temporary services..."

    if [[ -n "${TUNNEL_PID:-}" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        kill "$TUNNEL_PID" 2>/dev/null
        sleep 0.2
        kill -0 "$TUNNEL_PID" 2>/dev/null && kill -KILL "$TUNNEL_PID" 2>/dev/null
        wait "$TUNNEL_PID" 2>/dev/null
    fi

    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null
        sleep 0.2
        kill -0 "$SERVER_PID" 2>/dev/null && kill -KILL "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
    fi

    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
        rm -rf -- "$WORK_DIR"
    fi

    ok_msg "Temporary files removed."
    ok_msg "Source directory was not modified."

    if (( rc == 0 )); then
        ok_msg "Share session ended."
    elif (( rc == 130 || rc == 143 )); then
        ok_msg "Share session stopped by user."
    else
        warn_msg "Share session ended with exit code $rc."
    fi

    return 0
}

trap cleanup EXIT
trap 'exit 130' INT TERM

usage() {
    cat <<USAGE
Temporary File Share v${SCRIPT_VERSION}

Usage:
  $0 /path/to/folder

Examples:
  $0 /root/swiftslate-secrets
  $0 /var/backups/project

The source directory is read-only from this script's point of view.
Only the generated ZIP is exposed publicly through Cloudflare.
USAGE
}

require_privilege_path() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO=""
        return
    fi

    if have sudo; then
        SUDO="sudo"
        return
    fi

    # We can still proceed if all required tools are already installed
    # and cloudflared can live in ~/.local/bin.
    info "Running without root/sudo; installation will only work if dependencies are already available or user-local installation is possible."
}

package_install() {
    local pm=""
    local -a pkgs=()

    if have apt-get; then
        pm="apt"
        pkgs=(curl ca-certificates python3 zip unzip)
        export DEBIAN_FRONTEND=noninteractive
        $SUDO apt-get update
        $SUDO apt-get install -y "${pkgs[@]}"
    elif have dnf; then
        pm="dnf"
        pkgs=(curl ca-certificates python3 zip unzip)
        $SUDO dnf install -y "${pkgs[@]}"
    elif have yum; then
        pm="yum"
        pkgs=(curl ca-certificates python3 zip unzip)
        $SUDO yum install -y "${pkgs[@]}"
    elif have apk; then
        pm="apk"
        pkgs=(curl ca-certificates python3 zip unzip)
        $SUDO apk add --no-cache "${pkgs[@]}"
    elif have pacman; then
        pm="pacman"
        pkgs=(curl ca-certificates python zip unzip)
        $SUDO pacman -Sy --noconfirm "${pkgs[@]}"
    fi

    if [[ -n "$pm" ]]; then
        ok_msg "Dependencies installed/updated via $pm."
    else
        die "No supported package manager found. Install curl, ca-certificates, python3, zip and unzip manually."
    fi
}

ensure_dependencies() {
    local missing=()

    have curl || missing+=(curl)
    have python3 || missing+=(python3)
    have zip || missing+=(zip)
    have unzip || missing+=(unzip)
    have sha256sum || have openssl || missing+=(sha256-tool)

    if ((${#missing[@]} > 0)); then
        info "Missing prerequisites: ${missing[*]}"
        package_install
    fi

    have curl || die "curl is required."
    have python3 || die "python3 is required."
    have zip || die "zip is required."
    have unzip || die "unzip is required for ZIP validation."
    (have sha256sum || have openssl) || die "sha256sum or openssl is required."

    ok_msg "Base dependencies are available."
}

absolute_dir() {
    local input="$1"
    local resolved

    resolved="$(cd -- "$input" && pwd -P)" || return 1
    printf '%s\n' "$resolved"
}

validate_source() {
    [[ $# -ge 1 ]] || { usage; exit 1; }
    [[ $# -eq 1 ]] || die "Expected exactly one source directory argument."

    [[ -d "$1" ]] || die "Source directory does not exist: $1"
    [[ -r "$1" ]] || die "Source directory is not readable: $1"

    SOURCE_DIR="$(absolute_dir "$1")"
    [[ "$SOURCE_DIR" != "/" ]] || die "Refusing to archive '/'. Choose a specific directory."

    SOURCE_NAME="$(basename -- "$SOURCE_DIR")"
    [[ -n "$SOURCE_NAME" && "$SOURCE_NAME" != "/" ]] || die "Could not determine a safe archive name."

    ZIP_NAME="${SOURCE_NAME}.zip"

    ok_msg "Source: $SOURCE_DIR"
    ok_msg "Archive name: $ZIP_NAME"
}

make_workdir() {
    local parent
    local candidate

    parent="$(dirname -- "$SOURCE_DIR")"

    # Prefer a temp directory next to the source's parent so that even
    # special cases such as /tmp are not accidentally archived into themselves.
    candidate=""
    if [[ -w "$parent" ]]; then
        candidate="$(mktemp -d -- "$parent/.share-file.XXXXXX" 2>/dev/null || true)"
    fi

    if [[ -z "$candidate" ]]; then
        candidate="$(mktemp -d /tmp/share-file.XXXXXX 2>/dev/null || true)"
    fi

    [[ -n "$candidate" && -d "$candidate" ]] || die "Could not create a secure temporary working directory."

    # Prevent the generated archive/runtime data from being inside the source tree.
    case "$candidate/" in
        "$SOURCE_DIR"/*)
            rm -rf -- "$candidate"
            die "Temporary directory would be inside the source tree; refusing to continue."
            ;;
    esac

    WORK_DIR="$candidate"
    SERVE_DIR="$WORK_DIR/public"
    CF_HOME="$WORK_DIR/cloudflare-home"

    mkdir -p -- "$SERVE_DIR" "$CF_HOME/.cloudflared"
    chmod 700 -- "$WORK_DIR" "$SERVE_DIR" "$CF_HOME" "$CF_HOME/.cloudflared"

    ok_msg "Temporary workspace created outside source tree."
}

sha256_file() {
    local file="$1"
    if have sha256sum; then
        sha256sum -- "$file" | awk '{print $1}'
    else
        openssl dgst -sha256 -- "$file" | awk '{print $NF}'
    fi
}

install_cloudflared_direct() {
    local arch asset api_json version digest download_path install_dir tmp_bin actual

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        i386|i686) arch="386" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7|armhf) arch="arm" ;;
        *) die "Unsupported CPU architecture for cloudflared: $(uname -m)" ;;
    esac

    info "Fetching the latest official cloudflared release metadata."

    api_json="$(curl -fsSL --retry 3 --connect-timeout 15 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: share-file-v2' \
        "$CF_API")" || die "Could not fetch cloudflared release metadata."

    read -r version asset digest < <(
        printf '%s' "$api_json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
assets = obj.get("assets", [])
wanted = "cloudflared-linux-" + sys.argv[1]
for a in assets:
    if a.get("name") == wanted:
        d = a.get("digest") or ""
        if d.startswith("sha256:"):
            d = d.split(":", 1)[1]
        print(obj.get("tag_name", ""), a.get("name", ""), d)
        raise SystemExit(0)
raise SystemExit("Requested cloudflared asset was not found")
' "$arch"
    )

    [[ -n "$version" && -n "$asset" && -n "$digest" ]] || die "Official release metadata did not contain a SHA-256 digest for $arch."

    info "Latest cloudflared release: $version ($asset)"

    tmp_bin="$WORK_DIR/cloudflared.download"
    download_path="${CF_DOWNLOAD_BASE}/${version}/${asset}"

    curl -fL --retry 3 --connect-timeout 15 \
        -H 'User-Agent: share-file-v2' \
        "$download_path" \
        -o "$tmp_bin" || die "Could not download cloudflared from the official release."

    actual="$(sha256_file "$tmp_bin")"
    [[ "$actual" == "$digest" ]] || {
        rm -f -- "$tmp_bin"
        die "cloudflared SHA-256 verification failed. Expected $digest, got $actual."
    }

    chmod 0755 -- "$tmp_bin"

    if [[ "$(id -u)" -eq 0 || -n "$SUDO" ]]; then
        install_dir="/usr/local/bin"
        $SUDO mkdir -p -- "$install_dir"
        $SUDO install -m 0755 -- "$tmp_bin" "$install_dir/cloudflared"
        CLOUDFLARED_BIN="$install_dir/cloudflared"
    else
        install_dir="${HOME:-/tmp}/.local/bin"
        mkdir -p -- "$install_dir"
        install -m 0755 -- "$tmp_bin" "$install_dir/cloudflared"
        CLOUDFLARED_BIN="$install_dir/cloudflared"
        export PATH="$install_dir:$PATH"
    fi

    rm -f -- "$tmp_bin"

    "$CLOUDFLARED_BIN" --version >/dev/null 2>&1 || die "cloudflared was installed but failed its executable check."
    ok_msg "cloudflared installed and SHA-256 verified."
}

ensure_cloudflared() {
    if have cloudflared; then
        CLOUDFLARED_BIN="$(command -v cloudflared)"
        "$CLOUDFLARED_BIN" --version >/dev/null 2>&1 || die "Existing cloudflared executable failed its version check."
        warn_msg "Using existing cloudflared: $CLOUDFLARED_BIN (provenance not re-verified)."
        return
    fi

    # Prefer Cloudflare's official package repository where documented.
    if have apt-get; then
        info "cloudflared not found; trying Cloudflare's official APT repository."
        if { [[ "$(id -u)" -eq 0 ]] || [[ -n "$SUDO" ]]; } && \
           $SUDO mkdir -p --mode=0755 /usr/share/keyrings && \
           curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | \
             $SUDO tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null && \
           printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | \
             $SUDO tee /etc/apt/sources.list.d/cloudflared.list >/dev/null && \
           $SUDO apt-get update && \
           $SUDO apt-get install -y cloudflared; then
            if have cloudflared; then
                CLOUDFLARED_BIN="$(command -v cloudflared)"
                "$CLOUDFLARED_BIN" --version >/dev/null 2>&1 || die "APT-installed cloudflared failed its version check."
                ok_msg "cloudflared installed via Cloudflare's official APT repository."
                return
            fi
        fi
        warn_msg "APT installation path did not complete; using the verified official release binary instead."
    fi

    # For other distros, the package repository details vary. Use the
    # official release binary with SHA-256 verification.
    install_cloudflared_direct
}

find_free_port() {
    local p
    for ((p=PORT_FIRST; p<=PORT_LAST; p++)); do
        if python3 - "$p" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("127.0.0.1", port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
raise SystemExit(0)
PY
        then
            PORT="$p"
            return 0
        fi
    done
    return 1
}

create_zip() {
    ZIP_PATH="$WORK_DIR/$ZIP_NAME"

    info "Creating archive..."

    (
        cd -- "$(dirname -- "$SOURCE_DIR")"
        zip -q -r "$ZIP_PATH" "$SOURCE_NAME"
    ) || die "ZIP creation failed."

    [[ -s "$ZIP_PATH" ]] || die "Created ZIP is empty."

    unzip -tqq -- "$ZIP_PATH" >/dev/null 2>&1 || die "ZIP integrity validation failed."

    # Copy only the ZIP to the public directory.
    cp -- "$ZIP_PATH" "$SERVE_DIR/$ZIP_NAME"
    chmod 600 -- "$SERVE_DIR/$ZIP_NAME"

    ok_msg "ZIP created and validated."
    ok_msg "Archive size: $(du -h -- "$ZIP_PATH" | awk '{print $1}')"
}

url_encode_path_segment() {
    python3 - "$1" <<'PY'
from urllib.parse import quote
import sys
print(quote(sys.argv[1], safe=""))
PY
}

start_http_server() {
    find_free_port || die "No free localhost port found in ${PORT_FIRST}-${PORT_LAST}."

    info "Starting localhost HTTP server on 127.0.0.1:$PORT."

    (
        cd -- "$SERVE_DIR"
        exec python3 -m http.server "$PORT" --bind 127.0.0.1
    ) >"$WORK_DIR/python.log" 2>&1 &
    SERVER_PID=$!

    sleep 0.5

    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        cat -- "$WORK_DIR/python.log" >&2 || true
        die "Python HTTP server failed to start."
    fi

    local encoded_name
    encoded_name="$(url_encode_path_segment "$ZIP_NAME")"

    curl -fsS -I --max-time 10 \
        "http://127.0.0.1:$PORT/$encoded_name" \
        >/dev/null || {
        cat -- "$WORK_DIR/python.log" >&2 || true
        die "Local HTTP validation failed."
    }

    ok_msg "Local HTTP server validated."
}

start_tunnel() {
    local tunnel_log="$WORK_DIR/cloudflared.log"
    local attempts=0
    local tunnel_url=""

    info "Starting Cloudflare Quick Tunnel."

    # Isolate HOME/XDG config so any existing ~/.cloudflared/config.yaml
    # cannot interfere with the temporary Quick Tunnel.
    HOME="$CF_HOME" \
    XDG_CONFIG_HOME="$CF_HOME/.config" \
    "$CLOUDFLARED_BIN" tunnel \
        --no-autoupdate \
        --url "http://127.0.0.1:$PORT" \
        >"$tunnel_log" 2>&1 &
    TUNNEL_PID=$!

    while (( attempts < 40 )); do
        tunnel_url="$(grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$tunnel_log" 2>/dev/null | head -n 1 || true)"

        if [[ -n "$tunnel_url" ]]; then
            break
        fi

        if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            cat -- "$tunnel_log" >&2 || true
            die "Cloudflare Quick Tunnel exited before producing a public URL."
        fi

        sleep 0.5
        ((attempts+=1))
    done

    [[ -n "$tunnel_url" ]] || {
        cat -- "$tunnel_log" >&2 || true
        die "Could not detect the Cloudflare Quick Tunnel URL."
    }

    local encoded_name
    encoded_name="$(url_encode_path_segment "$ZIP_NAME")"
    PUBLIC_URL="${tunnel_url}/${encoded_name}"

    ok_msg "Cloudflare tunnel URL detected."
}

verify_public_url() {
    local code=""
    local attempts=0

    info "Testing the public HTTPS endpoint."

    while (( attempts < 6 )); do
        code="$(curl -sS -L -I --max-time 12 \
            -o /dev/null \
            -w '%{http_code}' \
            "$PUBLIC_URL" 2>/dev/null || true)"

        case "$code" in
            200|204|206|301|302|303|307|308)
                ok_msg "Public endpoint responded with HTTP $code."
                return 0
                ;;
        esac

        sleep 1
        ((attempts+=1))
    done

    warn_msg "Public endpoint could not be verified from this VPS."
    warn_msg "The tunnel may still be reachable externally; test the displayed link from another device."
    return 1
}

print_result() {
    local verified="$1"
    local size
    size="$(du -h -- "$ZIP_PATH" | awk '{print $1}')"

    printf '\n'
    printf '%s\n' '============================================================'
    printf '  TEMPORARY PUBLIC DOWNLOAD  v%s\n' "$SCRIPT_VERSION"
    printf '%s\n' '============================================================'
    printf '\n'
    printf '  File   : %s\n' "$ZIP_NAME"
    printf '  Size   : %s\n' "$size"
    printf '  Server : 127.0.0.1:%s\n' "$PORT"
    printf '\n'
    printf '  DOWNLOAD LINK:\n'
    printf '  %s\n' "$PUBLIC_URL"
    printf '\n'

    if [[ "$verified" == "yes" ]]; then
        printf '  Status : VERIFIED\n'
    else
        printf '  Status : UNVERIFIED (external test recommended)\n'
    fi

    printf '\n'
    printf '%s\n' '============================================================'
    printf '\n'
    warn_msg "Anyone holding the link can download the ZIP while this session is running."
    warn_msg "Quick Tunnels are temporary/testing infrastructure, not a permanent file-hosting service."
    info "Press Ctrl+C to stop the tunnel and delete the temporary ZIP/runtime files."
}

monitor_tunnel() {
    while kill -0 "$TUNNEL_PID" 2>/dev/null; do
        sleep 1
    done

    cat -- "$WORK_DIR/cloudflared.log" >&2 || true
    die "Cloudflare Quick Tunnel stopped unexpectedly."
}

main() {
    umask 077

    printf '\n'
    printf '%s\n' '============================================================'
    printf '  TEMPORARY FILE SHARE v%s\n' "$SCRIPT_VERSION"
    printf '%s\n' '============================================================'
    printf '\n'

    require_privilege_path
    validate_source "$@"
    ensure_dependencies
    make_workdir
    ensure_cloudflared
    create_zip
    start_http_server
    start_tunnel

    if verify_public_url; then
        print_result yes
    else
        print_result no
    fi

    monitor_tunnel
}

main "$@"
