#!/usr/bin/env bash
#
# Stubbed regression tests for Install.sh.
#
# These tests are part of the safety contract for the installer: they run the
# real script, but only with harmless command stubs, a temporary HOME, and --
# for the cases that would normally touch /etc -- a user/mount namespace.
# They must never be pointed at a real sshd_config or a real tunnel provider.

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
INSTALL_SH="$REPO_ROOT/Install.sh"

TEST_ROOT=$(mktemp -d "/tmp/sshjc-install-tests-XXXXXX")
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
CASE_NUMBER=0
CASE_DIR=""
BIN_DIR=""
HOME_DIR=""
LAST_LOG=""
LAST_STATUS=0
DECOY_PIDS=()

cleanup() {
    local pid
    for pid in "${DECOY_PIDS[@]}"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    if [[ "${KEEP_TEST_ARTIFACTS:-0}" != "1" && "$TEST_ROOT" == /tmp/sshjc-install-tests-* ]]; then
        rm -rf -- "$TEST_ROOT"
    else
        echo "Test artifacts kept in: $TEST_ROOT"
    fi
}
trap cleanup EXIT

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s\n' "$1" >&2
    if [[ -n "$LAST_LOG" && -f "$LAST_LOG" ]]; then
        printf '%s\n' '--- Install.sh output (last 40 lines) ---' >&2
        tail -n 40 "$LAST_LOG" >&2 || true
        printf '%s\n' '--- end Install.sh output ---' >&2
    fi
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf 'SKIP: %s (%s)\n' "$1" "$2"
}

check() {
    local description=$1
    shift
    if "$@"; then
        pass "$description"
    else
        fail "$description"
    fi
}

write_stub() {
    local path=$1
    cat >"$path"
    chmod +x "$path"
}

new_case() {
    CASE_NUMBER=$((CASE_NUMBER + 1))
    CASE_DIR="$TEST_ROOT/case-$CASE_NUMBER"
    BIN_DIR="$CASE_DIR/bin"
    HOME_DIR="$CASE_DIR/home"
    LAST_LOG="$CASE_DIR/output.log"
    mkdir -p "$BIN_DIR" "$HOME_DIR"

    write_stub "$BIN_DIR/sudo" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
    exit 0
fi
exec "$@"
STUB

    write_stub "$BIN_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    is-active) exit "${TEST_SYSTEMCTL_IS_ACTIVE:-1}" ;;
    *) exit 0 ;;
esac
STUB

    write_stub "$BIN_DIR/pgrep" <<'STUB'
#!/usr/bin/env bash
exit "${TEST_PGREP_STATUS:-1}"
STUB

    write_stub "$BIN_DIR/sshd" <<'STUB'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"-T"* ]]; then
    printf '%s\n' \
        'passwordauthentication yes' \
        'permitrootlogin prohibit-password'
    if [[ "${TEST_SSHD_SFTP:-1}" == "1" ]]; then
        echo 'subsystem sftp internal-sftp'
    fi
    exit 0
fi
exit "${TEST_SSHD_T_STATUS:-0}"
STUB

    write_stub "$BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
out=""
previous=""
for arg in "$@"; do
    if [[ "$previous" == "-o" ]]; then
        out=$arg
    fi
    previous=$arg
done
if [[ -n "$out" ]]; then
    printf 'stub package\n' >"$out"
else
    printf '%s\n' 'not-json'
fi
exit 0
STUB

    write_stub "$BIN_DIR/dpkg" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_DPKG_LOG:?TEST_DPKG_LOG is not set}"
if [[ "${1:-}" == "--print-architecture" ]]; then
    echo amd64
fi
exit 0
STUB

    write_stub "$BIN_DIR/apt" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

    write_stub "$BIN_DIR/apt-get" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
}

# Runs Install.sh with a controlled PATH/HOME. Extra arguments are NAME=VALUE
# environment assignments. The real installer commands are not in this PATH
# unless a test deliberately adds a stub for them.
run_install() {
    local input=$1
    shift
    printf '%b' "$input" >"$CASE_DIR/input.txt"
    : >"$CASE_DIR/dpkg.log"
    env -i \
        PATH="$BIN_DIR:/usr/bin:/bin" \
        HOME="$HOME_DIR" \
        TERM=dumb \
        TEST_DPKG_LOG="$CASE_DIR/dpkg.log" \
        "$@" \
        timeout 20 bash "$INSTALL_SH" \
        <"$CASE_DIR/input.txt" >"$LAST_LOG" 2>&1
    LAST_STATUS=$?
}

output_contains() {
    grep -Fq -- "$1" "$LAST_LOG"
}

dpkg_did_not_install() {
    # The architecture probe is expected; invoking dpkg with -i is not.
    ! grep -Eq '(^| )-i( |$)' "$CASE_DIR/dpkg.log"
}

status_is_zero() {
    [[ "$LAST_STATUS" -eq 0 ]]
}

status_is_nonzero() {
    [[ "$LAST_STATUS" -ne 0 ]]
}

file_content_is() {
    local path=$1 expected=$2 actual
    [[ -f "$path" ]] || return 1
    actual=$(cat "$path")
    [[ "$actual" == "$expected" ]]
}

file_mode_is() {
    local path=$1 expected=$2 actual
    [[ -e "$path" ]] || return 1
    actual=$(stat -c '%a' "$path")
    [[ "$actual" == "$expected" ]]
}

test_reused_pid_is_never_killed() {
    new_case
    local tunnel_dir="$HOME_DIR/.setup-ssh-tunnel/tunnels/demo"
    mkdir -p "$tunnel_dir"
    sleep 30 &
    local decoy_pid=$!
    DECOY_PIDS+=("$decoy_pid")
    printf '%s\n' "$decoy_pid" >"$tunnel_dir/pid"
    printf '%s\n' '22' >"$tunnel_dir/port"

    run_install '6\n2\ny\n'

    check "reused PID: unrelated process is left alive" kill -0 "$decoy_pid"
    check "reused PID: warning explains that it was not killed" \
        output_contains "was NOT killed"
    check "reused PID: stale PID state is removed" \
        test ! -e "$tunnel_dir/pid"

    # Reap the decoy now so the test shell does not report it as a
    # terminated background job during global cleanup.
    kill "$decoy_pid" 2>/dev/null || true
    wait "$decoy_pid" 2>/dev/null || true
}

test_invalid_gui_tunnel_name_aborts() {
    new_case

    run_install '5\n' \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_TUNNEL_NAME='../evil'

    check "invalid GUI tunnel name: run fails" status_is_nonzero
    check "invalid GUI tunnel name: error is reported" \
        output_contains "Invalid SSHJC_TUNNEL_NAME"
}

test_invalid_fx_token_fails_before_state_write() {
    new_case

    run_install '4\n' \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_PROVIDER=fxtunnel \
        SSHJC_FX_TOKEN='sk_bad token' \
        SSHJC_TUNNEL_NAME=demo2

    check "invalid fx token: run fails" status_is_nonzero
    check "invalid fx token: format error is reported" \
        output_contains "Invalid fxTunnel token format"
    check "invalid fx token: no token state is written" \
        test ! -e "$HOME_DIR/.setup-ssh-tunnel/tunnels/demo2/token"
}

test_valid_fx_token_is_saved_privately() {
    new_case
    local token_file="$HOME_DIR/.setup-ssh-tunnel/tunnels/demo-good/token"

    run_install '4\n' \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_PROVIDER=fxtunnel \
        SSHJC_FX_TOKEN='sk_test_123' \
        SSHJC_TUNNEL_NAME=demo-good

    check "valid fx token: configuration succeeds" status_is_zero
    check "valid fx token: token state is saved" \
        file_content_is "$token_file" 'sk_test_123'
    check "valid fx token: token state is mode 600" \
        file_mode_is "$token_file" '600'
}

test_unverified_cloudflared_is_refused_in_gui_mode() {
    new_case

    run_install '3\n' \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_PROVIDER=cloudflared

    check "unverified cloudflared: GUI run fails closed" status_is_nonzero
    check "unverified cloudflared: refusal is explicit" \
        output_contains "refusing to install cloudflared without a verified checksum"
    check "unverified cloudflared: dpkg -i is never invoked" dpkg_did_not_install
}

test_invalid_cloudflared_version_is_rejected() {
    new_case

    # Interactive path: menu 3, provider 1, then the pinned-version prompt.
    run_install '3\n1\nbad/version\n'

    check "invalid cloudflared version: run fails" status_is_nonzero
    check "invalid cloudflared version: rejection is explicit" \
        output_contains "Invalid cloudflared version: 'bad/version'"
}

test_sshd_start_must_be_confirmed() {
    if [[ ! -d /run/systemd/system ]]; then
        skip "sshd running confirmation" "no systemd runtime directory"
        return
    fi

    new_case
    run_install '2\n' \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_ACCESS_MODE=3 \
        TEST_SYSTEMCTL_IS_ACTIVE=1 \
        TEST_PGREP_STATUS=1

    check "sshd not running: SSH-only run fails" status_is_nonzero
    check "sshd not running: failure is explicit" \
        output_contains "does not appear to be running"

    new_case
    run_install '2\n' \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_ACCESS_MODE=3 \
        TEST_SYSTEMCTL_IS_ACTIVE=0 \
        TEST_PGREP_STATUS=1

    check "sshd confirmed running: SSH-only run succeeds" status_is_zero
    check "sshd confirmed running: success is reported" \
        output_contains "sshd is running"
}

test_failed_background_tunnel_fails_gui_job() {
    new_case
    local tunnel_dir="$HOME_DIR/.setup-ssh-tunnel/tunnels/demo"
    mkdir -p "$tunnel_dir"
    printf '%s\n' 'fxtunnel' >"$HOME_DIR/.setup-ssh-tunnel/provider"
    printf '%s\n' 'sk_test_123' >"$tunnel_dir/token"

    write_stub "$BIN_DIR/fxtunnel" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

    run_install '5\n' \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_TUNNEL_NAME=demo \
        SSHJC_LOCAL_PORT=22 \
        SSHJC_RUN_MODE=2

    check "failed background tunnel: GUI job exits nonzero" status_is_nonzero
    check "failed background tunnel: failure is reported" \
        output_contains "Tunnel failed to start (GUI mode"
}

namespace_is_available() {
    command -v unshare &>/dev/null && unshare -rm true &>/dev/null
}

write_config_aware_sshd_stub() {
    write_stub "$BIN_DIR/sshd" <<'STUB'
#!/usr/bin/env bash
cfg=/etc/ssh/sshd_config
args="$*"
if [[ "$args" == *"-T"* ]]; then
    permit=$(awk 'tolower($1)=="permitrootlogin" {print $2; exit}' "$cfg")
    password=$(awk 'tolower($1)=="passwordauthentication" {print $2; exit}' "$cfg")
    printf 'permitrootlogin %s\n' "${permit:-prohibit-password}"
    printf 'passwordauthentication %s\n' "${password:-yes}"
    echo 'subsystem sftp internal-sftp'
    exit 0
fi
exit 0
STUB
}

test_sshd_directive_append_and_backup_guard() {
    if ! namespace_is_available || [[ ! -d /etc/ssh ]]; then
        skip "sshd directive append" "user/mount namespace unavailable"
        skip "sshd backup guard" "user/mount namespace unavailable"
        return
    fi

    new_case
    write_config_aware_sshd_stub
    mkdir -p "$CASE_DIR/fake-ssh"
    printf '%s\n' 'Port 22' 'PasswordAuthentication yes' \
        >"$CASE_DIR/fake-ssh/sshd_config"

    write_stub "$CASE_DIR/run-in-namespace.sh" <<'RUNNER'
#!/usr/bin/env bash
mount --bind "$1" /etc/ssh || exit 97
exec bash "$2"
RUNNER

    # Perform this invocation explicitly: the generic runner cannot append
    # the fake-config and installer paths after the namespace runner path.
    env -i \
        PATH="$BIN_DIR:/usr/bin:/bin" \
        HOME="$HOME_DIR" \
        TERM=dumb \
        TEST_DPKG_LOG="$CASE_DIR/dpkg.log" \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_ACTION=update_sshd_security \
        SSHJC_PERMIT_ROOT_LOGIN=prohibit-password \
        timeout 20 unshare -rm "$CASE_DIR/run-in-namespace.sh" \
            "$CASE_DIR/fake-ssh" "$INSTALL_SH" \
        >"$LAST_LOG" 2>&1
    LAST_STATUS=$?

    check "missing sshd directive: update succeeds" status_is_zero
    check "missing sshd directive: directive is appended" \
        grep -Fxq 'PermitRootLogin prohibit-password' "$CASE_DIR/fake-ssh/sshd_config"
    check "sshd edit: a backup is created first" \
        test -n "$(find "$CASE_DIR/fake-ssh" -maxdepth 1 -name 'sshd_config.bak-*' -print -quit)"

    new_case
    write_config_aware_sshd_stub
    mkdir -p "$CASE_DIR/fake-ssh"
    printf '%s\n' 'Port 22' 'PasswordAuthentication yes' \
        >"$CASE_DIR/fake-ssh/sshd_config"
    printf '%s\n' 'Port 22' 'PasswordAuthentication yes' \
        >"$CASE_DIR/expected-sshd_config"

    write_stub "$BIN_DIR/cp" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

    write_stub "$CASE_DIR/run-in-namespace.sh" <<'RUNNER'
#!/usr/bin/env bash
mount --bind "$1" /etc/ssh || exit 97
exec bash "$2"
RUNNER

    env -i \
        PATH="$BIN_DIR:/usr/bin:/bin" \
        HOME="$HOME_DIR" \
        TERM=dumb \
        TEST_DPKG_LOG="$CASE_DIR/dpkg.log" \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_ACTION=update_sshd_security \
        SSHJC_PERMIT_ROOT_LOGIN=prohibit-password \
        timeout 20 unshare -rm "$CASE_DIR/run-in-namespace.sh" \
            "$CASE_DIR/fake-ssh" "$INSTALL_SH" \
        >"$LAST_LOG" 2>&1
    LAST_STATUS=$?

    check "backup failure: sshd update fails" status_is_nonzero
    check "backup failure: edit refusal is explicit" \
        output_contains "Refusing to edit sshd_config without a backup"
    check "backup failure: sshd_config is unchanged" \
        cmp -s "$CASE_DIR/expected-sshd_config" "$CASE_DIR/fake-ssh/sshd_config"
}

test_toggle_sftp_failure_is_propagated() {
    if ! namespace_is_available || [[ ! -d /etc/ssh ]]; then
        skip "toggle_sftp failure propagation" "user/mount namespace unavailable"
        return
    fi

    new_case
    mkdir -p "$CASE_DIR/fake-ssh" "$CASE_DIR/empty"
    printf '%s\n' 'Port 22' >"$CASE_DIR/fake-ssh/sshd_config"

    write_stub "$CASE_DIR/run-in-namespace.sh" <<'RUNNER'
#!/usr/bin/env bash
mount --bind "$1" /etc/ssh || exit 97
# Hide every packaged sftp-server location known to Install.sh.
for directory in /usr/lib/openssh /usr/libexec/openssh /usr/lib/ssh; do
    if [[ -d "$directory" ]]; then
        mount --bind "$3" "$directory" || exit 97
    fi
done
exec bash "$2"
RUNNER

    env -i \
        PATH="$BIN_DIR:/usr/bin:/bin" \
        HOME="$HOME_DIR" \
        TERM=dumb \
        TEST_DPKG_LOG="$CASE_DIR/dpkg.log" \
        TEST_SSHD_SFTP=0 \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_ACTION=toggle_sftp \
        timeout 20 unshare -rm "$CASE_DIR/run-in-namespace.sh" \
            "$CASE_DIR/fake-ssh" "$INSTALL_SH" "$CASE_DIR/empty" \
        >"$LAST_LOG" 2>&1
    LAST_STATUS=$?

    check "toggle_sftp without sftp-server: action exits nonzero" status_is_nonzero
    check "toggle_sftp without sftp-server: cause is reported" \
        output_contains "Could not locate the sftp-server binary"
    check "toggle_sftp failure: no Subsystem line is appended" \
        test "$(grep -c '^Subsystem' "$CASE_DIR/fake-ssh/sshd_config" || true)" = "0"
}

test_fx_systemd_run_saves_port_and_private_unit() {
    if ! namespace_is_available || [[ ! -d /etc/systemd/system || ! -d /run/systemd/system ]]; then
        skip "fxTunnel systemd state" "user/mount namespace or systemd unavailable"
        return
    fi

    new_case
    local tunnel_dir="$HOME_DIR/.setup-ssh-tunnel/tunnels/demo"
    mkdir -p "$tunnel_dir" "$CASE_DIR/fake-systemd"
    printf '%s\n' 'fxtunnel' >"$HOME_DIR/.setup-ssh-tunnel/provider"
    printf '%s\n' 'sk_test_123' >"$tunnel_dir/token"

    write_stub "$BIN_DIR/fxtunnel" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

    write_stub "$CASE_DIR/run-in-namespace.sh" <<'RUNNER'
#!/usr/bin/env bash
mount --bind "$1" /etc/systemd/system || exit 97
exec bash "$2"
RUNNER

    printf '%s\n' '5' >"$CASE_DIR/input.txt"
    env -i \
        PATH="$BIN_DIR:/usr/bin:/bin" \
        HOME="$HOME_DIR" \
        TERM=dumb \
        TEST_DPKG_LOG="$CASE_DIR/dpkg.log" \
        TEST_SYSTEMCTL_IS_ACTIVE=0 \
        SSHJC_NONINTERACTIVE=1 \
        SSHJC_TUNNEL_NAME=demo \
        SSHJC_LOCAL_PORT=22 \
        SSHJC_RUN_MODE=3 \
        timeout 20 unshare -rm "$CASE_DIR/run-in-namespace.sh" \
            "$CASE_DIR/fake-systemd" "$INSTALL_SH" \
        <"$CASE_DIR/input.txt" >"$LAST_LOG" 2>&1
    LAST_STATUS=$?

    local unit="$CASE_DIR/fake-systemd/fxtunnel-demo.service"
    check "fxTunnel systemd run: succeeds with an active unit" status_is_zero
    check "fxTunnel systemd run: unit contains the token environment" \
        grep -Fxq 'Environment=FXTUNNEL_TOKEN=sk_test_123' "$unit"
    check "fxTunnel systemd run: unit is mode 600" file_mode_is "$unit" '600'
    check "fxTunnel systemd run: exposed port is saved" \
        file_content_is "$tunnel_dir/port" '22'
    check "fxTunnel systemd run: service name is saved" \
        file_content_is "$tunnel_dir/service" 'fxtunnel-demo'
}

main() {
    [[ -x "$INSTALL_SH" ]] || {
        echo "Install.sh is missing or not executable: $INSTALL_SH" >&2
        exit 1
    }

    test_reused_pid_is_never_killed
    test_invalid_gui_tunnel_name_aborts
    test_invalid_fx_token_fails_before_state_write
    test_valid_fx_token_is_saved_privately
    test_unverified_cloudflared_is_refused_in_gui_mode
    test_invalid_cloudflared_version_is_rejected
    test_sshd_start_must_be_confirmed
    test_failed_background_tunnel_fails_gui_job
    test_sshd_directive_append_and_backup_guard
    test_toggle_sftp_failure_is_propagated
    test_fx_systemd_run_saves_port_and_private_unit

    echo
    printf 'Install.sh regression summary: %d passed, %d failed, %d skipped\n' \
        "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
    [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
