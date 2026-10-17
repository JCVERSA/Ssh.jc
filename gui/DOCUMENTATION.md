# SSH.JC Control Center — Architecture & Operations Guide

## 1. Executive Summary
**SSH.JC Control Center** is a web management console for OpenSSH servers, Cloudflare Tunnels (`cloudflared`), and fxTunnel SaaS endpoints. As of Phase 2, it no longer re-implements installer logic: every mutating operation executes the repository's own [`Install.sh`](../Install.sh) in its non-interactive GUI mode, keeping the script as the single source of truth. The console adds password authentication, parameter validation, live job logs, and a safeguard that prevents tunnels from targeting the console's own port.

---

## 2. Protected Infrastructure & Safeguard Architecture

### Critical Protection: the console port
The Control Center protects **its own listening port** (`GUI_PORT`, default `3000`): exposing the console through a tunnel would publish a management interface that can run installers.
- **Port Locking**: Frontend validation and the backend job validator reject any job whose `localPort` equals the console port.
- **Isolation**: SSH operations default to port `22` (or operator-configured ports like `2222`), preserving the console port unharmed.
- The safeguard follows `GUI_PORT` if the console is moved to another port; it is not tied to a specific number or hosting environment.

---

## 3. Direct Mapping to Official `Install.sh` Capabilities

All jobs spawn `bash Install.sh` (located via `SSHJC_SCRIPT_PATH`, default `../Install.sh`) with `SSHJC_NONINTERACTIVE=1`. Parameters travel in `SSHJC_*` environment variables; the few prompts remaining in GUI mode are answered, in order, on stdin.

| Job type | Control Center feature | Script entry |
| :--- | :--- | :--- |
| `full_setup` | Install Wizard (Option 1) | Menu 1 (+ SSH access mode via `SSHJC_ACCESS_MODE`) |
| `install_openssh` | SSH Management / Wizard (Option 2) | Menu 2 (access configuration skipped) |
| `configure_admin_user` | SSH Management | Menu 2 with `SSHJC_USERNAME` / `SSHJC_PUBKEY` |
| `install_tunnel_client` | Install Wizard (Option 3) | Menu 3 |
| `configure_tunnel` | Install Wizard (Option 4) | Menu 4 (+ `SSHJC_DOMAIN` / `SSHJC_SUBDOMAIN` / `SSHJC_FX_TOKEN`) |
| `run_tunnel` | Tunnel Manager / Wizard (Option 5) | Menu 5 (+ `SSHJC_RUN_MODE`) |
| `stop_tunnel` | Tunnel Manager & Dashboard | Menu 6 → stop action for `SSHJC_TUNNEL_NAME` |
| `update_sshd_security` | SSH Management | `SSHJC_ACTION=update_sshd_security` (+ directive env vars) |
| `toggle_sftp` | SSH Management | `SSHJC_ACTION=toggle_sftp` |

**Smart connection commands**: `GET /api/system/status` returns, per tunnel, the ready-to-paste `connectCommand` — Cloudflare: `ssh -o ProxyCommand="cloudflared access ssh --hostname …" user@host`; fxTunnel: `ssh -p <port> user@host` with the dynamically assigned endpoint parsed from the tunnel log (`TCP: host:port`) or the systemd journal. The wizard's completion panel and Tunnel Manager display it automatically (polled, no reload). Already-installed dependencies (sshd, cloudflared, fxtunnel) are detected and skipped by `Install.sh`; the wizard badges those steps "already present".

GUI-mode contract in `Install.sh`: prompts read answers from stdin and fail fast on EOF (never block on a TTY); interactive-only actions (root password change, browser-based `cloudflared tunnel login`) are refused with a clear error; `update_sshd_security` validates with `sshd -t` and restores the timestamped backup on failure.

---

## 4. Security & Safety Controls

1. **Authentication**: All API routes except `/api/health` and `/api/auth/*` require a session. Passwords are scrypt-hashed (see §6), compared in constant time, and login is rate-limited per IP. Session cookies are `HttpOnly`, `SameSite=Lax` (+ `Secure` behind HTTPS).
2. **Anti-Command Injection**: No arbitrary shell commands are accepted from the browser. Jobs run a fixed script with an allowlisted environment and no shell interpolation of user input.
3. **Secret Redaction**: API tokens (`sk_...`), private keys, and credentials are scrubbed from stdout/stderr, log files, and API responses; the fx token never appears in job records (stored as `***`).
4. **Concurrency Locking**: A global mutex ensures conflicting operations cannot run concurrently. Jobs run in their own process group with a 15-minute timeout; cancel terminates the whole tree.
5. **Configuration Preservation & Backups**: `sshd_config` updates create a timestamped backup (`sshd_config.bak-<timestamp>`) and are verified with `sshd -t`/`sshd -T` before the job reports success (handled inside `Install.sh`).

---

## 5. API Reference

### Authentication & Health
- `GET /api/health`: Open. Returns server status, uptime, and timestamp.
- `POST /api/auth/login`: Body `{ password }`. Sets the session cookie.
- `POST /api/auth/logout`: Clears the session.
- `GET /api/auth/session`: Returns `{ authenticated: boolean }`.
- All other routes return `401` without a valid session.

### System
- `GET /api/system/status`: System info, OpenSSH status, tunnels, safeguard metadata, active job.
- `GET /api/system/safeguards`: Protection specifications for the console port.
- `GET /api/system/logs?limit=100`: Aggregated system log stream with level tags (`info`, `ok`, `warn`, `error`).

### Operations & Jobs
- `POST /api/jobs/execute`: Starts an asynchronous job.
  - Body: `{ type: "full_setup" | "install_openssh" | "install_tunnel_client" | "configure_tunnel" | "run_tunnel" | "stop_tunnel" | "configure_admin_user" | "update_sshd_security" | "toggle_sftp", parameters: {...} }`
- `GET /api/jobs/active`: Currently executing job.
- `GET /api/jobs/history`: Recently executed jobs.
- `GET /api/jobs/:id`: Job status, exit code, and live logs.
- `POST /api/jobs/:id/cancel`: Terminates the running job's process group.

### SSH & Tunnels
- `GET /api/ssh/config`: Inspects `/etc/ssh/sshd_config` and lists recovery backups.
- `POST /api/tunnels/stop`: Stops an active tunnel by name (script menu 6).

---

## 6. Installation & Launch Instructions

> Full VPS walkthrough (systemd unit, updates, troubleshooting): see [DEPLOYMENT.md](DEPLOYMENT.md).

### Configuration (`.env` or environment)
```bash
GUI_PORT=3000                 # console port (protected from tunnels)
GUI_PASSWORD=change-me        # console password (plaintext), OR:
# GUI_PASSWORD_HASH=...       # preferred: npm run set-password -- 'your-password'
# SSHJC_SCRIPT_PATH=/path/to/Install.sh   # optional override
```
Without `GUI_PASSWORD`/`GUI_PASSWORD_HASH`, a random password is generated and printed once in the server log.

### Development & Local Testing
```bash
npm install
npm test          # automated suite (uses a stub script; never runs Install.sh)
npm run dev       # Express API + Vite middleware on GUI_PORT
```

### Production
```bash
npm run build
NODE_ENV=production npm start
```

### Target Deployment (same VPS as Install.sh)
1. Clone `JCVERSA/Ssh.jc` on the VPS; the console lives in `gui/` and finds `../Install.sh` automatically.
2. Install Node.js 20+ and run `npm install` inside `gui/`.
3. Set `GUI_PASSWORD` (or a hash) in the environment; run as a sudo-capable user so jobs can manage `sshd` and `/etc/ssh/sshd_config`.
4. Reach the console over SSH port-forwarding or a **separate, access-controlled** tunnel — never a public tunnel on the console port (the safeguard only blocks tunnel *jobs*, not your own ingress choices).

---

## 7. Automated Test Results
Executed via `npm test` (`tsx test/api.test.ts`) — job execution is pointed at a stub via `SSHJC_SCRIPT_PATH`, so tests never invoke the real installer:
- `Secret Redaction: masks fxTunnel API tokens (sk_...)`: **PASSED**
- `Secret Redaction: masks OpenSSH private keys`: **PASSED**
- `Safeguard: rejects operations targeting protected Port 3000`: **PASSED**
- `Validation: allows legitimate SSH port 22 or custom ports`: **PASSED**
- `Validation: rejects out-of-range ports`: **PASSED**
- `Security: rejects invalid tunnel names containing shell metacharacters`: **PASSED**
- `Validation: accepts standard OpenSSH public keys (RSA, Ed25519, ECDSA)`: **PASSED**
- `Validation: rejects corrupted or invalid public keys`: **PASSED**
- `Concurrency Lock: blocks concurrent overlapping execution jobs`: **PASSED**
- `Script Driver: update_sshd_security maps to SSHJC_ACTION with env params`: **PASSED**
- `Script Driver: stop_tunnel answers menu 6 stop sequence`: **PASSED**
- `Script Driver: fx token never appears in the job summary`: **PASSED**
- `Auth: scrypt hash verifies the right password and rejects wrong ones`: **PASSED**
- `Binary Guard: hasBinary accurately detects installed vs missing system tools`: **PASSED**

**Overall Test Suite: 14 Passed, 0 Failed.**
