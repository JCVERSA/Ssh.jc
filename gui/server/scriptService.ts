// Bridge between the Control Center backend and Install.sh.
//
// Single source of truth: every mutating job executes the repository's
// Install.sh in its non-interactive GUI mode (SSHJC_NONINTERACTIVE=1).
// Parameters travel through SSHJC_* environment variables; the few prompts
// the script still asks in GUI mode are answered, in order, on stdin.
// Native re-implementations previously duplicated script logic and drifted
// from it; they have been removed.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import type { JobType } from './types.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export interface ScriptInvocation {
  scriptPath: string;
  env: Record<string, string>;
  /** Answers fed to the script's stdin, one per line, in prompt order. */
  stdinAnswers: string[];
  /** Human-readable parameter summary for the job log (no secrets). */
  summary: string;
}

/** Locate Install.sh: explicit override, repo root relative to gui/, cwd. */
export function findInstallScript(): string {
  const candidates: string[] = [];
  if (process.env.SSHJC_SCRIPT_PATH) candidates.push(process.env.SSHJC_SCRIPT_PATH);
  candidates.push(path.resolve(__dirname, '../../Install.sh')); // gui/ sits one level below the repo root
  candidates.push(path.resolve(process.cwd(), '../Install.sh'));
  candidates.push(path.resolve(process.cwd(), 'Install.sh'));
  for (const candidate of candidates) {
    try {
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // keep looking
    }
  }
  return candidates[1];
}

function providerEnvValue(provider: unknown): string | undefined {
  if (provider === 'fxtunnel') return 'fxtunnel';
  if (provider === 'cloudflared') return 'cloudflared';
  return undefined;
}

/**
 * Translate a GUI job into an Install.sh invocation.
 *
 * Prompt order per flow (GUI mode) — see Install.sh:
 *  - SSH step: SSHJC_ACCESS_MODE replaces the access choice; when an admin
 *    user is created WITH a key, one confirm remains ("disable password
 *    authentication for ALL accounts?").
 *  - full setup ends with "Start the tunnel now?" (answered 'y').
 *  - tunnel management (stop) asks for an action (2 = stop) then confirms.
 */
export function buildInvocation(type: JobType, params: Record<string, any>): ScriptInvocation {
  const scriptPath = findInstallScript();
  const env: Record<string, string> = { SSHJC_NONINTERACTIVE: '1' };
  const summaryParts: string[] = [];

  const setEnv = (key: string, value: unknown, secret = false) => {
    if (value === undefined || value === null || value === '') return;
    env[key] = String(value);
    summaryParts.push(`${key}=${secret ? '***' : String(value)}`);
  };

  const provider = providerEnvValue(params.provider);
  if (provider) setEnv('SSHJC_PROVIDER', provider);
  if (params.tunnelName) setEnv('SSHJC_TUNNEL_NAME', params.tunnelName);
  if (params.domain) setEnv('SSHJC_DOMAIN', params.domain);
  if (params.subdomain) setEnv('SSHJC_SUBDOMAIN', params.subdomain);
  if (params.localPort !== undefined && params.localPort !== '') setEnv('SSHJC_LOCAL_PORT', params.localPort);
  // GUI runMode vocabulary ('background' | 'systemd') -> script menu numbers.
  if (params.runMode) setEnv('SSHJC_RUN_MODE', params.runMode === 'systemd' ? '3' : '2');

  let stdinAnswers: string[] = [];

  switch (type) {
    case 'full_setup': {
      const hasUser = Boolean(params.username);
      if (params.username) setEnv('SSHJC_USERNAME', params.username);
      if (params.pubkey !== undefined) setEnv('SSHJC_PUBKEY', params.pubkey);
      setEnv('SSHJC_FX_TOKEN', params.fxToken, true);
      setEnv('SSHJC_ACCESS_MODE', hasUser ? '1' : '3');
      stdinAnswers = ['1'];
      if (hasUser && params.pubkey) {
        stdinAnswers.push(params.disablePasswordAuth ? 'y' : 'n'); // disable-password confirm
      }
      stdinAnswers.push('y'); // "Start the tunnel now?"
      break;
    }
    case 'install_openssh': {
      // SSH install only: skip user/access configuration entirely.
      setEnv('SSHJC_ACCESS_MODE', '3');
      stdinAnswers = ['2'];
      break;
    }
    case 'install_tunnel_client': {
      stdinAnswers = ['3', 'y']; // menu, confirm running the official installer
      break;
    }
    case 'configure_tunnel': {
      setEnv('SSHJC_FX_TOKEN', params.fxToken, true);
      stdinAnswers = ['4'];
      break;
    }
    case 'run_tunnel': {
      stdinAnswers = ['5'];
      break;
    }
    case 'stop_tunnel': {
      // Menu 6: pick tunnel (SSHJC_TUNNEL_NAME honoured), action 2, confirm.
      stdinAnswers = ['6', '2', 'y'];
      break;
    }
    case 'configure_admin_user': {
      if (params.username) setEnv('SSHJC_USERNAME', params.username);
      if (params.pubkey !== undefined) setEnv('SSHJC_PUBKEY', params.pubkey);
      setEnv('SSHJC_ACCESS_MODE', '1');
      stdinAnswers = ['2'];
      if (params.pubkey) {
        stdinAnswers.push(params.disablePasswordAuth ? 'y' : 'n');
      }
      break;
    }
    case 'update_sshd_security': {
      env.SSHJC_ACTION = 'update_sshd_security';
      setEnv('SSHJC_PERMIT_ROOT_LOGIN', params.permitRootLogin);
      setEnv('SSHJC_PASSWORD_AUTHENTICATION', params.passwordAuthentication);
      break;
    }
    case 'toggle_sftp': {
      env.SSHJC_ACTION = 'toggle_sftp';
      break;
    }
    default: {
      throw new Error(`Unsupported job type: ${type}`);
    }
  }

  return {
    scriptPath,
    env,
    stdinAnswers,
    summary: summaryParts.length ? summaryParts.join(' ') : '(no parameters)',
  };
}
