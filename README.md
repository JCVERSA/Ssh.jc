# Ssh.jc

Bash installers for remote access and temporary file sharing on Linux
(Ubuntu/Debian focus). Interactive, single-file scripts — no build step.

| Script | What it does | Exposure |
|---|---|---|
| `Install.sh` | Installs OpenSSH and exposes SSH through a Cloudflare Tunnel (named tunnel + DNS hostname) **or** fxTunnel (TCP). Menu-driven, with state kept across runs. | SSH reachable from the internet via your hostname — read the security notes. |
| `fxtunnel-installer.sh` | Installs the fxTunnel client and runs a persistent **UDP** tunnel (default port 19132, Minecraft Bedrock) in a `screen` session. Prompts are in French. | `<subdomain>.fxtun.dev` forwarded to your local UDP port. |
| `share-file-v2.sh` | Zips a folder and shares it temporarily through a Cloudflare Quick Tunnel. Only the ZIP is served; everything is deleted on exit (Ctrl+C). | Anyone with the link can download the ZIP while it runs. |

## Requirements

- Bash, on Ubuntu/Debian for `Install.sh` (`share-file-v2.sh` also supports
  dnf/yum/apk/pacman for its own dependencies).
- Root or sudo for the steps that install packages, edit `sshd_config`,
  create users, or install services.
- For `Install.sh` with Cloudflare: a domain already added to a Cloudflare
  account. For fxTunnel: an account/token from fxtun.dev.

## Usage

```bash
./Install.sh                  # interactive menu; ./Install.sh --help for details
./fxtunnel-installer.sh       # asks for token, subdomain, UDP port
./share-file-v2.sh /path/to/folder
```

## Security notes

- **`Install.sh`** makes SSH internet-reachable once the tunnel runs. Prefer
  the dedicated admin user + SSH key flow (menu option 1), disable password
  authentication when offered, and consider a Cloudflare Access policy in
  front of the hostname.
- Before the first edit in a run, `Install.sh` backs up `sshd_config` to
  `/etc/ssh/sshd_config.bak-<timestamp>` (restore:
  `sudo cp -a <backup> /etc/ssh/sshd_config`) and validates the result with
  `sshd -t` / `sshd -T`.
- API tokens are never passed on a command line (they would show in
  `ps aux`): both fxTunnel flows pass the token via the `FXTUNNEL_TOKEN`
  environment variable. `Install.sh` keeps per-tunnel state (including
  tokens) under `~/.setup-ssh-tunnel/` with `700`/`600` permissions.
- **`fxtunnel-installer.sh`** downloads the official installer to a file and
  asks for explicit confirmation before running it — fxtun.dev publishes no
  checksum for `install.sh` itself. The token prompt is hidden, and the
  generated `~/fxtunnel/start-fxtunnel.sh` is owner-only (`700`).
- **`share-file-v2.sh`** binds its local server to `127.0.0.1` only, verifies
  the downloaded cloudflared binary by SHA-256, and never modifies the
  source folder. Symbolic links are stored as links in the ZIP — targets
  outside the shared folder are never included. Quick Tunnel links are
  unauthenticated: anyone holding the link can download while the session
  runs, so don't share folders containing secrets.

## Development

CI (`.github/workflows/ci.yml`) runs `bash -n` and ShellCheck on every
push/PR. Run locally:

```bash
bash -n Install.sh fxtunnel-installer.sh share-file-v2.sh
shellcheck Install.sh fxtunnel-installer.sh share-file-v2.sh
```

See `AUDIT-2026-10-16-fullstack-v2.1.md` for the security/quality audit
these scripts were hardened against, including finding IDs (F-01…F-11)
referenced in code comments.

## Licence

No licence specified yet.
