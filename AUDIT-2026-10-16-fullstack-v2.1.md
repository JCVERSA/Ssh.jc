# Audit — Ssh.jc

| | |
|---|---|
| Date | 2026-10-16 |
| Method | `fullstack-engineering-agent-v2.1.md` — Mode A (Existing Project Audit) |
| Lifecycle | DISCOVER → ANALYZE → REPORT → **WAIT FOR APPROVAL** → IMPLEMENT → VALIDATE |
| Scope | `Install.sh`, `fxtunnel-installer.sh`, `share-file-v2.sh` (1,762 lines, 3 files) |
| Code modified in this phase | **None.** This report is the only file added. No script was executed. |

> Evidence rule (§2): claims below are labelled CONFIRMED (direct evidence), LIKELY
> (strong inference), UNKNOWN, or RECOMMENDATION. Nothing is presented as tested
> unless a command/test below proves it. Secrets found: **none** (values redacted
> by design — none existed to redact).

---

# Project Overview

**CONFIRMED:** Three standalone interactive Bash installers for remote access /
file sharing on Linux (Ubuntu/Debian focus). Single commit (`b3abbfa`,
"Add files via upload"), no README, no tests, no CI, no licence, no `.gitignore`.

| File | Lines | Purpose (from headers + code) |
|---|---|---|
| `Install.sh` | 1,058 | Interactive installer: OpenSSH server + Cloudflare Tunnel (named tunnel, DNS route) **or** fxTunnel (token, TCP). Menu modes 1–6. Stores per-tunnel state under `~/.setup-ssh-tunnel/`. |
| `fxtunnel-installer.sh` | 105 | Minimal installer: official `fxtunnel` client + persistent **UDP** tunnel (default 19132, Minecraft Bedrock) inside a `screen` session. Prompts in French. |
| `share-file-v2.sh` | 599 | Temporary public sharing: folder → ZIP → Python HTTP on localhost → Cloudflare **Quick Tunnel** (`*.trycloudflare.com`). Auto-cleans on exit. |

The two fxTunnel flows are **related but not identical** (SSH/TCP in `Install.sh`
vs. Bedrock/UDP in `fxtunnel-installer.sh`) — duplication is partial, not total.

# Evidence & Confidence

Commands actually run (read-only):

- `bash -n` syntax check on all 3 scripts → **PASS × 3**
- `grep` inventories: `curl|sh`, `eval`, secrets patterns, `rm -rf`, `chmod 777`,
  `mktemp` vs. predictable `/tmp`, `sudo`/`apt`/`sshd_config` edits, token handling
- `git log / ls-files -s` → 1 commit; all files mode `100644` (not executable)
- Sandbox reproduction (in `/tmp`, deleted after): `zip` symlink-following and
  default-permissions of the fxTunnel generated start script — both reproduced

**UNVERIFIED:** ShellCheck / static analysis (not installed in this environment;
not installed silently per §24). Runtime behaviour of any installer (none was
run — they install packages, edit `/etc/ssh/sshd_config`, create users, and open
public tunnels; running them for an audit would itself be a destructive action).
Network/API behaviour of cloudflared/fxtunnel (not exercised).

# Architecture Analysis

```text
Operator (interactive terminal, root/sudo)
   │
   ├─ Install.sh ──► OpenSSH (sshd) ──► cloudflared named tunnel ──► Cloudflare DNS hostname ──► ssh/sftp client (ProxyCommand)
   │                └──────────────► fxtunnel TCP ───────────────► fxtun.dev (dynamic host:port)
   │
   ├─ fxtunnel-installer.sh ──► fxtunnel UDP ──► <domain>.fxtun.dev  (via screen session)
   │
   └─ share-file-v2.sh ──► ZIP (only file served) ──► python http.server 127.0.0.1 ──► Cloudflare Quick Tunnel ──► anyone with link
```

- **Trust boundaries:** (1) download sources (`github.com`, `pkg.cloudflare.com`,
  `fxtun.dev`) → local root/sudo execution; (2) local host → public internet via
  tunnels (SSH becomes internet-reachable); (3) share link → anonymous download.
- **Coupling:** low between files (no shared library); high *within* `Install.sh`
  (1,058-line linear script, execution at top level, no `main` guard — sourcing
  it would run it).
- **State:** `Install.sh` keeps state in `~/.setup-ssh-tunnel/` (dir `700`,
  files `600` — CONFIRMED good); `fxtunnel-installer.sh` keeps the API token in
  a generated script (see F-02).

# Technology Stack

CONFIRMED from code: Bash (5.x syntax), OpenSSH server, cloudflared,
fxTunnel client, Python 3 (`http.server`), `zip`/`unzip`, `screen`, `systemd`
(optional path), `apt`/`dnf`/`yum`/`apk`/`pacman` (share-file only), GitHub
Releases + Cloudflare APT repo as distribution channels. No database, no build
system, no package manager manifest.

# Dependency Review

| Dependency | How obtained | Integrity |
|---|---|---|
| cloudflared (`Install.sh`) | `.deb` from GitHub Releases (`latest` or pinned tag) | SHA-256 verified when GitHub API digest available; otherwise explicit user confirmation — CONFIRMED in code |
| cloudflared (`share-file-v2.sh`) | Cloudflare APT repo, fallback GitHub binary | SHA-256 verified on binary path — CONFIRMED |
| fxtunnel (`Install.sh`) | `fxtun.dev/install.sh` downloaded to `mktemp` file | No checksum exists for the script; explicit confirmation before running — CONFIRMED |
| fxtunnel (`fxtunnel-installer.sh`) | `curl … \| bash` | **None — see F-01** |
| `jq`, `openssh-server`, `screen`, python/zip… | `apt` | Distro trust only (normal for apt) |

RECOMMENDATION: pin/record resolved versions at install time (partially done:
`Install.sh` allows pinning cloudflared; neither script logs the fxtunnel version installed).

# Security Findings

Findings use §9 severity (not inflated) and §10 format.

---

```text
ID:         F-01
Severity:   HIGH
Confidence: CONFIRMED
Category:   Supply chain / remote code execution
Location:   fxtunnel-installer.sh:24
Problem:    curl -fsSL https://fxtun.dev/install.sh | bash — remote script executed
            immediately, no download-to-file, no checksum, no review prompt.
Evidence:   grep match on line 24. Contrast: Install.sh:523-545 downloads the same
            installer to an mktemp file, warns no checksum exists, and requires
            explicit confirmation before running it.
Impact:     Anyone compromising fxtun.dev (or the connection path beyond TLS)
            gets code execution with the operator's privileges at install time.
Root Cause: Convenience install path copied from vendor docs without the
            integrity/confirmation guard the sibling script already implements.
Fix:        Download to mktemp file, print path, warn + confirm (mirror
            Install.sh), verify checksum if fxtun.dev publishes one.
Regression Risk: Low — same install result, one extra prompt.
```

```text
ID:         F-02
Severity:   HIGH
Confidence: CONFIRMED
Category:   Secrets handling
Location:   fxtunnel-installer.sh:39, 76-82
Problem:    (a) API token read without `read -s` (echoed to terminal/scrollback);
            (b) token interpolated in plaintext into ~/fxtunnel/start-fxtunnel.sh;
            (c) that file is chmod +x only — reproduced in sandbox: with umask 022
            the generated file is -rw-r--r-- (readable by every local user);
            (d) token also passed as CLI arg → visible in `ps aux` while running.
Evidence:   Lines 39, 76-79, 82; sandbox reproduction of generated-file perms.
Impact:     Any local user (or any process that can read the home dir / process
            list) can steal the fxtun.dev API token.
Root Cause: Token treated as ordinary config rather than a credential.
Fix:        `read -rs` for the prompt; store token in a 600-permission file or
            environment file; chmod 600 the start script (0700 dir); prefer
            env-var passing like Install.sh:931 if the client supports it.
Regression Risk: Low.
```

```text
ID:         F-03
Severity:   MEDIUM
Confidence: CONFIRMED
Category:   Input validation / injection into generated code
Location:   fxtunnel-installer.sh:45-58, 76-79, 87-93
Problem:    LOCAL_PORT, FX_DOMAIN, FX_SERVER, SCREEN_NAME accepted with no
            validation (only non-empty checks) and expanded UNQUOTED into the
            generated start script (heredoc, line 79) and into a grep pattern
            (line 87). Install.sh:820-830 validates the same port properly.
Evidence:   Lines above; no regex/range check exists in the file.
Impact:     Typos silently produce a broken tunnel; crafted values (spaces,
            shell metacharacters, regex chars, ../) break the generated script
            or alter the command it runs when the screen session starts it.
Root Cause: Missing validation layer present in the sibling script.
Fix:        Validate port 1-65535 (base-10), domain/server against a strict
            pattern, screen name against [A-Za-z0-9._-]+; quote variables in
            the generated script (printf %q or single-quote heredoc + args).
Regression Risk: Low — legitimate values unaffected.
```

```text
ID:         F-04
Severity:   MEDIUM
Confidence: CONFIRMED (no validation exists); exploitability LIKELY
Category:   Input validation / path safety
Location:   Install.sh:211 (username), 684/723 (tunnel name), 304-308 (state paths),
            967 (mktemp template built from TUNNEL_NAME)
Problem:    Username and tunnel name flow unvalidated into useradd, /home/<name>
            paths, chown, ${STATE_DIR}/tunnels/<name>/… file paths and a /tmp
            mktemp template. A value containing `/`, `..`, leading `-` or spaces
            can escape the intended directory or be parsed as command options.
Evidence:   grep shows no allowlist check at any of these call sites.
Impact:     Local file writes outside the state dir; confusing failures; in the
            worst case writes where the operator did not intend (script runs
            with sudo for many steps, though state_set itself is unprivileged).
Root Cause: Interactive input trusted as a safe path component.
Fix:        One allowlist validator (e.g. ^[a-z_][a-z0-9_-]*$ for usernames,
            ^[A-Za-z0-9._-]+$ with `..` rejected for tunnel names) applied
            before first use.
Regression Risk: Low — normal names pass.
```

```text
ID:         F-05
Severity:   MEDIUM
Confidence: CONFIRMED
Category:   Reliability / recoverability
Location:   Install.sh — all `sed -i … /etc/ssh/sshd_config` sites (195, 435, 439,
            459, 463, 148-150); no backup exists (grep for backup/.bak: none)
Problem:    sshd_config is edited in place with no timestamped backup. The script
            does validate with `sshd -t` / `sshd -T` afterwards (CONFIRMED good),
            but a bad intermediate state has no one-command rollback.
Impact:     Lockout risk is mitigated by validation, recovery is manual.
Fix:        `cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak-<timestamp>`
            (root-only perms) before the first edit; print the restore command.
Regression Risk: Very low.
```

```text
ID:         F-06
Severity:   MEDIUM
Confidence: CONFIRMED
Category:   Secrets handling (inconsistency)
Location:   Install.sh:861 (argv token for foreground/background), vs. 931-932
Problem:    The systemd path deliberately keeps the fxTunnel token out of
            ExecStart (Environment= in a 600 unit), but foreground/nohup paths
            pass `-t <token>` on the command line → visible in `ps aux`.
Evidence:   Lines 861, 911-932 (the good pattern), 961 (correctly masked in logs).
Fix:        Export token via environment for fg/bg too, if the client accepts it;
            otherwise document the exposure. Verify client support before claiming.
Regression Risk: Low. (Client env support: UNKNOWN — must be checked at implement time.)
```

```text
ID:         F-07
Severity:   MEDIUM
Confidence: CONFIRMED (reproduced in sandbox)
Category:   Data exposure
Location:   share-file-v2.sh:404 (`zip -q -r`, no -y/--symlinks option)
Problem:    Info-ZIP follows symlinks by default: a symlink inside the shared
            folder pointing outside it is archived as the TARGET's contents.
Evidence:   Sandbox test: src/link.txt → /tmp/…/outside.txt archived and extracted
            as "OUTSIDE-SECRET". The share-file header promises "expose only the
            generated ZIP, never the source tree" — symlink targets are neither.
Impact:     Files outside the chosen folder can be published to anyone with the
            link, contrary to the tool's stated design goal.
Root Cause: Default zip symlink behaviour not accounted for.
Fix:        Add `-y` (store links as links) or detect symlinks and warn/refuse;
            document the chosen semantics in the header.
Regression Risk: Low — folders without symlinks unchanged; with symlinks, the
            ZIP entries change type (must be disclosed in the change report).
```

Lower-severity / design notes (details in Code Quality & UI/UX below):

- **F-08 (LOW, by design, CONFIRMED):** Quick Tunnel link is unauthenticated —
  anyone with it can download. The script *does* warn (lines 558-559) and is
  honest about UNVERIFIED status (537-540). However `usage()` (line 117) shows
  `$0 /root/swiftslate-secrets` as an example — RECOMMENDATION: change the
  example; never normalise sharing a "secrets" folder publicly.
- **F-09 (LOW):** `Install.sh` uses `set -uo pipefail` **without `-e`** (line 14).
  Many steps check results explicitly (good), but failures in unchecked steps
  let an interactive run continue in a partial state. LIKELY intentional for an
  interactive installer; RECOMMENDATION: document or audit step-by-step rather
  than blindly adding `-e` (would change behaviour — needs care).
- **F-10 (LOW):** `fxtunnel-installer.sh:69` runs `apt` without `sudo` and with
  `set -e` — fails abruptly for non-root users (its sibling scripts handle
  root/sudo explicitly).
- **F-11 (LOW):** `share-file-v2.sh` free-port probe (find_free_port) has a
  classic check-then-bind race; impact negligible for a local temporary tool.
- **Good patterns to keep (CONFIRMED):** SHA-256 verification of cloudflared;
  `mktemp` (no predictable `/tmp`); state files `600`/dirs `700`; `sshd -T`
  effective-config checks incl. drop-in override warning; key de-duplication;
  port validation (`10#` base-10); token masked in log output; ZIP integrity
  test; HTTP bound to `127.0.0.1` only; `umask 077`; cleanup `trap`; isolated
  Cloudflare HOME in share-file. **Do not regress these.**

# Critical Issues

None confirmed. (No CRITICAL per §9: no authentication bypass, data corruption,
or production-blocking defect was evidenced. F-01/F-02 are HIGH.)

# High Priority Issues

- F-01 — `curl | bash` unverified remote execution (`fxtunnel-installer.sh:24`)
- F-02 — fxTunnel API token echoed, stored plaintext, world-readable generated
  script, exposed in process list (`fxtunnel-installer.sh:39, 76-82`)

# Medium Priority Issues

- F-03 — Unvalidated input expanded unquoted into generated code (`fxtunnel-installer.sh`)
- F-04 — Unvalidated username/tunnel name used in paths (`Install.sh`)
- F-05 — No `sshd_config` backup before in-place edits (`Install.sh`)
- F-06 — fxTunnel token on command line in fg/bg modes (`Install.sh:861`)
- F-07 — ZIP follows symlinks out of the shared folder (`share-file-v2.sh:404`)

# Low Priority Issues

- F-08 — "secrets" folder as usage example; unauthenticated link (by design, warned)
- F-09 — `set -e` absent in `Install.sh` (likely intentional; audit before changing)
- F-10 — `apt` without sudo in `fxtunnel-installer.sh:69`
- F-11 — Port probe race in `share-file-v2.sh` (negligible)
- Scripts committed mode `100644` — users must `chmod +x` first (git mode fix: `100755`)
- Language/naming inconsistency: French prompts (`fxtunnel-installer.sh`) vs.
  English elsewhere; `Install.sh` capitalisation differs from siblings

# Code Quality

- `share-file-v2.sh`: best structure — 26 functions, `main()` guard, strict
  modes, consistent helpers. **Model for the others.**
- `Install.sh`: 21 functions but 1,058 lines, top-level execution (banner at
  line 318 runs on source), duplicated provider branching. Extracting shared
  validators (port, names) would cut drift with `fxtunnel-installer.sh`.
  21 inline `FIX (…)` comments document a real audit history — keep that habit.
- `fxtunnel-installer.sh`: 0 functions, linear, weakest validation — the drift
  between it and `Install.sh`'s fxTunnel path is already visible (integrity
  check, token handling, port validation all missing here).
- No lint config, no tests, no CI anywhere (CONFIRMED: only 3 files in repo).

# Performance

No measured bottleneck; installers are I/O/interactive bound. §18: no optimisation
recommended from intuition. NOT RUN: any benchmark (none is meaningful here).

# Reliability

- `Install.sh`: systemd + foreground + nohup modes; PID/log persisted (good).
  Missing `sshd_config` backup is the main recoverability gap (F-05).
- `fxtunnel-installer.sh`: persistence = `screen` session only (dies on reboot,
  no restart policy); checks session exists 2s after start — reasonable for its
  size, but a reboot silently kills the Bedrock tunnel. RECOMMENDATION: offer
  the systemd unit pattern `Install.sh` already has, or document the limitation.
- `share-file-v2.sh`: cleanup trap kills children and removes temp dir;
  `set -E` + trap inheritance is correct. Strong.

# Testing

CONFIRMED: zero automated tests. Minimum viable (proposed): `bash -n` +
ShellCheck in CI; extraction-free smoke tests are hard for interactive scripts —
a pragmatic first step is ShellCheck + a `--help`/usage-path test for
`share-file-v2.sh` only. Full test harnesses for interactive installers are
**not** recommended yet (§6: no complexity without measurable value).

# UI/UX

CLI UX only (no GUI; Design Mode §22-25 not applicable — no frontend exists).
Positives: colour-coded status, confirmations before dangerous steps, masked
token in logs, honest VERIFIED/UNVERIFIED share status. Gaps: French/English
mix across scripts; `fxtunnel-installer.sh` echoes the token prompt (F-02a);
no `--help` in `Install.sh`/`fxtunnel-installer.sh` (`share-file-v2.sh` has usage).

# Feature Opportunities

(RECOMMENDATIONS, not defects) — unify shared validators into the small scripts;
`--dry-run`/check mode for `Install.sh`; record installed versions in state dir;
optional Cloudflare Access reminder already present — keep.

# Technical Debt

Duplicated tunnel logic across files with uneven security controls (root cause
of F-01/F-02/F-03); monolithic `Install.sh`; no README (install order, root
requirements, and the three scripts' differing purposes are undiscoverable
without reading 1,762 lines).

# Recommended Improvements

In §15 implementation order (security → blockers → bugs → … → docs):

1. **Phase 1 — `fxtunnel-installer.sh` security:** F-01, F-02, F-03, F-10.
2. **Phase 2 — `Install.sh` hardening:** F-04, F-05, F-06 (F-06 only if client
   env-token support confirmed; else document).
3. **Phase 3 — `share-file-v2.sh`:** F-07 (+ disclose ZIP change), F-08 example.
4. **Phase 4 — repo hygiene:** README (purpose/prereqs/usage per script),
   exec bit `100755`, ShellCheck config + CI (`bash -n` + shellcheck), keep
   changes minimal; no refactoring of `Install.sh` structure in this pass.

Explicitly **not** recommended now: rewriting `Install.sh`, extracting a shared
library, adding a test framework, dependency upgrades (none exist to upgrade).

# Proposed Execution Plan

```text
1. Phase 1 patch (fxtunnel-installer.sh) -> bash -n + manual diff review
2. Phase 2 patch (Install.sh)            -> bash -n + manual diff review
3. Phase 3 patch (share-file-v2.sh)      -> bash -n + local ZIP symlink re-test
4. Phase 4 (README, modes, CI)           -> git diff review
Each phase separately reviewable/revertible; no phase touches another's files.
```

# Validation Plan

```text
Build:      N/A (no build) — bash -n per file: PASS (baseline, pre-change)
Tests:      NOT RUN (none exist) — symlink ZIP reproduction test for Phase 3
Lint:       NOT RUN (ShellCheck unavailable; add in Phase 4 CI)
Type Check: N/A (Bash)
Security:   PARTIAL (pattern audit + 2 sandbox reproductions; no runtime audit)
Runtime:    NOT RUN (installers intentionally not executed — they modify
            /etc/ssh, users, packages and open public tunnels)
```

# Unknowns / Information Gaps

- UNKNOWN: whether the `fxtunnel` client accepts its token via environment
  variable (decides F-06 fix shape). Check: client `--help`/docs at implement time.
- UNKNOWN: intended audience per script (personal VPS vs. distribution to
  others) — affects how much Phase 4 documentation matters.
- UNKNOWN: whether `fxtunnel-installer.sh` is meant to run as root (it calls
  bare `apt`) — F-10 fix depends on the answer.
- UNVERIFIED: ShellCheck findings (tool unavailable here).

---

```text
Confirmed Problems:
- F-01 curl|bash unverified install (fxtunnel-installer.sh:24) — HIGH
- F-02 token echoed + plaintext in 644 generated script + ps exposure — HIGH
- F-03 unvalidated input into generated script (fxtunnel-installer.sh) — MEDIUM
- F-04 unvalidated username/tunnel name in paths (Install.sh) — MEDIUM
- F-05 no sshd_config backup before edits (Install.sh) — MEDIUM
- F-06 token on command line in fg/bg modes (Install.sh:861) — MEDIUM
- F-07 zip follows symlinks outside shared folder (share-file-v2.sh:404) — MEDIUM
- Repo: no README/tests/CI; scripts not executable in git — LOW

Likely Problems:
- Exploitability of F-04 path traversal (depends on operator input; script is
  interactive and operator-supplied, so real-world risk is bounded)

Recommendations:
- Phases 1-4 above; keep all CONFIRMED good patterns; do not rewrite Install.sh;
  change the "secrets" usage example; document screen-vs-systemd reboot behaviour

Unknown:
- fxtunnel env-token support; intended audience; root assumption of
  fxtunnel-installer.sh; ShellCheck results

Execution Order:
1. Approve scope (Phase 1 only / Phases 1-3 / all / none)
2. Implement approved phase(s), smallest patches, preserve behaviour otherwise
3. Validate per Validation Plan; report with STATUS line (§17)
```

**STATUS: AUDIT ONLY — NO CODE CHANGED — AWAITING APPROVAL (§3 Mode A)**

Validation of this report itself:
```text
Build: N/A   Tests: NOT RUN (none exist)   Lint: NOT RUN (ShellCheck unavailable)
Syntax (bash -n): PASS ×3   Security review: PARTIAL (static + reproduced F-02/F-07)
NOT VERIFIED: runtime behaviour of all three installers (intentionally not executed)
```

---

## Addendum — implementation status (2026-10-16, after approval)

All four phases were approved one at a time and implemented (smallest patches;
no other behaviour changed):

- **Phase 1 — `fxtunnel-installer.sh`:** F-01 (no more `curl | bash`; download +
  warning + explicit confirmation), F-02 (masked token prompt; `~/fxtunnel`
  and start script `700`), F-03 (validated inputs, `%q`-escaped generated
  script, `grep -qF`), F-10 (root-or-sudo for `apt`). Later add-on: token now
  also passed via `FXTUNNEL_TOKEN`, never as `--token` argv.
- **Phase 2 — `Install.sh`:** F-04 (`is_valid_username` / `is_valid_tunnel_name`
  at every prompt + saved-state guard), F-05 (`backup_sshd_config_once` before
  every `sshd_config` edit; restore command printed), F-06 (token via
  `FXTUNNEL_TOKEN` in foreground/background/systemd; vendor env support
  confirmed in fxtun.dev docs).
- **Phase 3 — `share-file-v2.sh`:** F-07 (`zip -y`: symlinks stored as links,
  listed with a warning; verified outside targets no longer archived),
  F-08 (usage example no longer a "secrets" folder).
- **Phase 4 — repo hygiene:** this README reference, scripts executable in
  git (`100755`), `.shellcheckrc` (two justified note-level disables), and
  CI (`.github/workflows/ci.yml`: `bash -n` + executable check + ShellCheck).

Validation summary: `bash -n` PASS ×3; ShellCheck 0.11.0 PASS (0 findings,
with the two justified note disables above); function-level/stub tests for
validators, sshd_config backup, env-token passing, and the ZIP symlink case
all PASS. Live runtime (real Cloudflare/fxTunnel execution as root) NOT RUN.

STATUS: IMPLEMENTED — NOT FULLY VERIFIED (live runtime remains UNVERIFIED)

## Addendum II — Install.sh improvements (post-audit, user-requested)

- New menu 6) Manage tunnels: per-tunnel status (systemd service or
  background PID), log tail, stop, and restart — using the per-tunnel
  state saved under ~/.setup-ssh-tunnel/tunnels/<name>/. Run/start flows
  now also record the service name and local port to make this possible.
- Menu 5 now picks from saved tunnels (numbered, Enter = last used)
  instead of relying on the last-used name alone.
- `./Install.sh --help` / `-h` prints usage and exits before any side
  effect (no log or state created).
