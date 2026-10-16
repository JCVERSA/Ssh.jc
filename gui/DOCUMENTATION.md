# SSH.JC Control Center — Architecture & Operations Guide

## 1. Executive Summary
**SSH.JC Control Center** is a production-ready web management console for OpenSSH servers, Cloudflare Tunnels (`cloudflared`), and fxTunnel SaaS endpoints. It faithfully implements the operations defined in the official [JCVERSA/Ssh.jc](https://raw.githubusercontent.com/JCVERSA/Ssh.jc/refs/heads/main/Install.sh) installer while enforcing strict system safeguards to protect existing host infrastructure.

---

## 2. Protected Infrastructure & Safeguard Architecture

### Critical Protection: Host Port 3000
The runtime environment already runs a protected Cloudflare tunnel and Node.js process on **port 3000** for the AI Studio preview environment.
- **Port Locking**: Both frontend validation and server-side middleware strictly prohibit binding, tunneling, or redirecting port `3000`.
- **Pre-Flight Safeguard**: Any job attempting `localPort: 3000` is immediately rejected with HTTP 403 (`SAFEGUARD DENIED`).
- **Isolation**: SSH operations default to port `22` (or operator-configured ports like `2222`), preserving port `3000` unharmed.

---

## 3. Direct Mapping to Official `Install.sh` Capabilities

| Script Menu Option | Control Center Feature | Backend Subprocess / API |
| :--- | :--- | :--- |
| **1) Full setup** | **Install Wizard (Option 1)** | `apt-get install openssh-server` + `cloudflared/fxtunnel` + DNS Route + Run |
| **2) OpenSSH server only** | **SSH Management / Wizard (Option 2)** | `apt-get install openssh-server`, start `sshd`, create admin user, authorized_keys dedup |
| **3) Install tunnel client only** | **Install Wizard (Option 3)** | Downloads `cloudflared-linux-{arch}.deb` with sha256 check or `fxtun.dev/install.sh` |
| **4) Create / configure tunnel** | **Install Wizard (Option 4)** | `cloudflared tunnel create`, `cloudflared tunnel route dns`, or fxTunnel token storage |
| **5) Run configured tunnel** | **Tunnel Manager / Wizard (Option 5)** | Runs background `nohup` or `systemd` unit with port validation |
| **6) Stop / Status** | **Tunnel Manager & Dashboard** | Graceful process termination (`SIGTERM`) or `systemctl stop` |

---

## 4. Security & Safety Controls

1. **Anti-Command Injection**: Zero arbitrary shell commands are accepted from the browser. Operations use fixed allowlisted handlers and argument arrays (`spawn`).
2. **Secret Redaction**: API tokens (`sk_...`), private keys, and credentials are automatically scrubbed from stdout/stderr, log files, and API responses.
3. **Concurrency Locking**: A global mutex ensures that conflicting installation or tunnel operations cannot run concurrently.
4. **Configuration Preservation & Backups**: Any update to `/etc/ssh/sshd_config` creates an atomic timestamped backup (`sshd_config.bak.<timestamp>`) and executes syntax verification (`sshd -t`) before applying.
5. **Authorized Keys Deduplication**: Public keys submitted are validated for standard OpenSSH format and checked with `grep -qF` before appending to prevent file corruption.

---

## 5. API Reference

### System & Health
- `GET /api/health`: Returns server status, uptime, and timestamp.
- `GET /api/system/status`: Returns comprehensive system info, OpenSSH status, tunnels, and port 3000 safeguard metadata.
- `GET /api/system/safeguards`: Returns protection specifications for locked port 3000.
- `GET /api/system/logs?limit=100`: Aggregated system log stream with level tags (`info`, `ok`, `warn`, `error`).

### Operations & Jobs
- `POST /api/jobs/execute`: Starts an asynchronous allowlisted job.
  - Body: `{ type: "full_setup" | "install_openssh" | "install_tunnel_client" | "configure_tunnel" | "run_tunnel" | "stop_tunnel" | "configure_admin_user" | "update_sshd_security" | "toggle_sftp", parameters: {...}, dryRun: boolean }`
- `GET /api/jobs/active`: Polls currently executing job.
- `GET /api/jobs/history`: Returns list of recently executed jobs.
- `GET /api/jobs/:id`: Returns specific job status, exit code, and live logs.
- `POST /api/jobs/:id/cancel`: Gracefully stops the running job process via `SIGTERM`.

### SSH & Tunnels
- `GET /api/ssh/config`: Inspects `/etc/ssh/sshd_config` and list of recovery backups.
- `POST /api/tunnels/stop`: Terminate an active tunnel by name.

---

## 6. Installation & Launch Instructions

### Development & Local Testing
```bash
# 1. Install dependencies
npm install

# 2. Run automated test suite
npm test

# 3. Start full-stack application (Express API on port 3000 with Vite middleware)
npm run dev
```

### Production Build & Container Deployment
```bash
# 1. Build frontend bundle
npm run build

# 2. Start production server
NODE_ENV=production npm start
```

### Target Container Deployment
To deploy into a dedicated VPS or container:
1. Transfer files or clone the repository into `/opt/ssh-jc-control-center`.
2. Ensure Node.js 18+ and `tsx` or standard node are installed.
3. Configure `PORT=3000` (or custom environment variable).
4. Run as an administrative or sudo-capable user to manage `sshd` and `/etc/ssh/sshd_config`.

---

## 7. Automated Test Results
Executed via `npm test` (`tsx test/api.test.ts`):
- `Secret Redaction: masks fxTunnel API tokens (sk_...)`: **PASSED**
- `Secret Redaction: masks OpenSSH private keys`: **PASSED**
- `Safeguard: rejects operations targeting protected Port 3000`: **PASSED**
- `Validation: allows legitimate SSH port 22 or custom ports`: **PASSED**
- `Validation: rejects out-of-range ports`: **PASSED**
- `Security: rejects invalid tunnel names containing shell metacharacters`: **PASSED**
- `Validation: accepts standard OpenSSH public keys (RSA, Ed25519, ECDSA)`: **PASSED**
- `Validation: rejects corrupted or invalid public keys`: **PASSED**
- `Concurrency Lock: blocks concurrent overlapping execution jobs`: **PASSED**

**Overall Test Suite: 9 Passed, 0 Failed.**
