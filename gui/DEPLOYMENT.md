# SSH.JC Control Center — VPS Deployment Guide

Deploy the web console on the **same VPS** as `Install.sh`. The console does
not replace the scripts: every operation runs `/opt/Ssh.jc/Install.sh` in its
non-interactive GUI mode.

> ⚠️ The console can run installers and edit `sshd_config`. Treat its
> password like a root password, and never expose it on a public tunnel
> without an additional access layer (see “Accessing the console”).

## 1. Prerequisites

- Debian/Ubuntu VPS where you already use `Ssh.jc`.
- Node.js **20+** and npm (`node --version`).
- A sudo-capable user (the example unit below runs as `root`; a dedicated
  sudo user works too).

## 2. Install

```bash
sudo git clone https://github.com/JCVERSA/Ssh.jc.git /opt/Ssh.jc
# (or: cd /opt/Ssh.jc && sudo git pull)
cd /opt/Ssh.jc/gui
sudo npm ci          # full install (tsx is needed at runtime)
npm test             # optional sanity check — never touches the system
```

## 3. Configure

Create `/opt/Ssh.jc/gui/.env` (already git-ignored):

```bash
cd /opt/Ssh.jc/gui
cp .env.example .env
# choose a strong password:
npm run set-password -- 'your-strong-password'
# paste the printed GUI_PASSWORD_HASH=... line into .env,
# and set GUI_PORT if 3000 is taken.
chmod 600 .env
```

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `GUI_PORT` | `3000` | Console port. Tunnels are forbidden from targeting it. |
| `GUI_PASSWORD` | — | Plaintext console password (hashed in memory at boot). |
| `GUI_PASSWORD_HASH` | — | Preferred: `scrypt$…` from `npm run set-password`. |
| `SSHJC_SCRIPT_PATH` | `../Install.sh` | Override only if the layout differs. |

If neither password variable is set, a random password is generated and
printed **once** in the server log at startup.

## 4. Run with systemd (recommended)

```bash
sudo cp /opt/Ssh.jc/gui/sshjc-control-center.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sshjc-control-center
systemctl status sshjc-control-center
journalctl -u sshjc-control-center -f   # logs (incl. generated password, if any)
```

Manual alternative (foreground, for a first look):

```bash
cd /opt/Ssh.jc/gui
sudo npm run build      # builds the frontend bundle (dist/)
sudo npm start          # NODE_ENV=production, serves dist/ + API on GUI_PORT
```

## 5. Accessing the console

Pick **one**:

1. **SSH port-forward (simplest, recommended):**
   `ssh -L 3000:127.0.0.1:3000 user@your-vps` then open
   `http://localhost:3000`.
2. **Your own tunnel + access control:** if you publish the console through
   Cloudflare, put Cloudflare Access (or equivalent) in front of it. The
   built-in safeguard stops *console jobs* from tunneling the console port,
   but it cannot stop an operator-created tunnel — that choice is yours.

Sign in with the password from step 3. Sessions last 12 hours; use the
**Sign out** button (top right) on shared machines.

## 6. Update & rollback

```bash
cd /opt/Ssh.jc && sudo git pull
cd gui && sudo npm ci && sudo npm run build
sudo systemctl restart sshjc-control-center
```

Rollback: `git checkout <previous-commit>` in `/opt/Ssh.jc`, rebuild, restart.
`sshd_config` changes made by jobs always leave `sshd_config.bak-<timestamp>`
backups in `/etc/ssh/` (restore:
`sudo cp -a /etc/ssh/sshd_config.bak-<timestamp> /etc/ssh/sshd_config`).

## 7. Troubleshooting

| Symptom | Check |
| :--- | :--- |
| Service fails to start | `journalctl -u sshjc-control-center -n 50` — port already in use? `.env` malformed? |
| “Invalid password” | `GUI_PASSWORD_HASH` must start with `scrypt$`; regenerate via `npm run set-password`. Plain `GUI_PASSWORD` also works. |
| Job fails immediately | Open the job log in the UI; `Install.sh` GUI mode fails fast with a clear `[ERROR]` (e.g. missing Cloudflare certificate → run `cloudflared tunnel login` once in a terminal). |
| Jobs hang up to 15 min | A prompt expected more input than provided — report the job type; the backend kills jobs at 15 minutes. |
| 401 on every page | Session expired (12 h) or cookies blocked; sign in again. |
