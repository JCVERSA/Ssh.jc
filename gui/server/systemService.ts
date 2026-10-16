import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';
import os from 'os';
import { SystemInfo, SshStatus, TunnelInstance, ProtectedInfrastructure, LogEntry } from './types.js';

const HOME_DIR = process.env.HOME || '/root';
const STATE_DIR = path.join(HOME_DIR, '.setup-ssh-tunnel');

function safeExec(command: string): string {
  try {
    return execSync(command, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch {
    return '';
  }
}

export function redactSecrets(text: string): string {
  if (!text) return '';
  return text
    .replace(/(sk_[a-zA-Z0-9_\-]{8,})/g, 'sk_***REDACTED***')
    .replace(/(-----BEGIN [A-Z\s]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z\s]+ PRIVATE KEY-----)/g, '[***PRIVATE KEY REDACTED***]')
    .replace(/(password[=:\s]+)([^\s,;]+)/gi, '$1***REDACTED***');
}

export function getProtectedInfra(): ProtectedInfrastructure {
  let pid: number | undefined;
  try {
    // Find node or vite process on port 3000
    const psOut = safeExec("ps aux | grep -E 'vite|server\\.ts' | grep -v grep | head -n 1");
    if (psOut) {
      const parts = psOut.trim().split(/\s+/);
      if (parts[1]) pid = parseInt(parts[1], 10);
    }
  } catch {
    // ignore
  }

  return {
    port: 3000,
    process: 'Node.js / Vite & Express Control Plane',
    pid: pid || process.pid,
    isLocked: true,
    reason: 'Host container port 3000 is dedicated to the AI Studio preview environment and existing Cloudflare ingress. Repurposing or tunneling over this port will sever application connectivity.',
    allowedOrigins: ['localhost:3000', '127.0.0.1:3000'],
    alertMessage: 'Protected: Port 3000 is locked by system safeguard. SSH.JC tunnels must select port 22 or custom non-conflicting ports.'
  };
}

export function getSystemInfo(): SystemInfo {
  let osName = 'Linux';
  let distroId = 'debian';
  if (fs.existsSync('/etc/os-release')) {
    try {
      const content = fs.readFileSync('/etc/os-release', 'utf8');
      const prettyMatch = content.match(/PRETTY_NAME="?([^"\n]+)"?/);
      if (prettyMatch) osName = prettyMatch[1];
      const idMatch = content.match(/^ID=([^\n]+)/m);
      if (idMatch) distroId = idMatch[1].replace(/"/g, '');
    } catch {
      // fallback
    }
  }

  let architecture = os.arch();
  const dpkgArch = safeExec('dpkg --print-architecture 2>/dev/null');
  if (dpkgArch) architecture = dpkgArch;

  const hasSystemd = fs.existsSync('/run/systemd/system');
  const isRoot = typeof process.getuid === 'function' ? process.getuid() === 0 : true;
  const hasSudo = isRoot || safeExec('which sudo 2>/dev/null') !== '';

  const cloudflaredPath = safeExec('which cloudflared 2>/dev/null');
  let cloudflaredVersion: string | undefined;
  if (cloudflaredPath) {
    const v = safeExec('cloudflared --version 2>/dev/null');
    cloudflaredVersion = v.split('\n')[0] || undefined;
  }

  const fxtunnelPath = safeExec('which fxtunnel 2>/dev/null');
  let fxtunnelVersion: string | undefined;
  if (fxtunnelPath) {
    const v = safeExec('fxtunnel --version 2>/dev/null');
    fxtunnelVersion = v.split('\n')[0] || undefined;
  }

  const jqInstalled = safeExec('which jq 2>/dev/null') !== '';

  let activeProvider: 'cloudflared' | 'fxtunnel' | 'none' = 'none';
  const providerFile = path.join(STATE_DIR, 'provider');
  if (fs.existsSync(providerFile)) {
    try {
      const val = fs.readFileSync(providerFile, 'utf8').trim();
      if (val === 'cloudflared' || val === 'fxtunnel') activeProvider = val;
    } catch {
      // ignore
    }
  }

  return {
    osName,
    distroId,
    architecture,
    hasSystemd,
    hasSudo,
    isRoot,
    cloudflaredInstalled: Boolean(cloudflaredPath),
    cloudflaredVersion,
    fxtunnelInstalled: Boolean(fxtunnelPath),
    fxtunnelVersion,
    jqInstalled,
    stateDir: STATE_DIR,
    activeProvider,
    protectedInfra: getProtectedInfra()
  };
}

export function getSshStatus(): SshStatus {
  const sshdPath = safeExec('which sshd 2>/dev/null') || (fs.existsSync('/usr/sbin/sshd') ? '/usr/sbin/sshd' : '');
  const isInstalled = Boolean(sshdPath);

  let isRunning = false;
  let pid: number | undefined;
  let listeningPort = 22;

  const pgrep = safeExec('pgrep -x sshd 2>/dev/null');
  if (pgrep) {
    isRunning = true;
    const pids = pgrep.split('\n').filter(Boolean);
    if (pids.length > 0) pid = parseInt(pids[0], 10);
  }

  let serviceMode: 'systemd' | 'standalone' | 'none' = 'none';
  if (fs.existsSync('/run/systemd/system')) {
    const systemdActive = safeExec('systemctl is-active ssh 2>/dev/null') === 'active' || safeExec('systemctl is-active sshd 2>/dev/null') === 'active';
    if (systemdActive) {
      isRunning = true;
      serviceMode = 'systemd';
    }
  } else if (isRunning) {
    serviceMode = 'standalone';
  }

  let version: string | undefined;
  if (isInstalled) {
    const ver = safeExec('ssh -V 2>&1');
    if (ver) version = ver.split('\n')[0];
  }

  let permitRootLogin: 'yes' | 'prohibit-password' | 'no' | 'unknown' = 'unknown';
  let passwordAuthentication: 'yes' | 'no' | 'unknown' = 'unknown';
  let sftpActive = false;

  // Try sshd -T first to get effective configuration
  const sshdT = safeExec('sudo sshd -T 2>/dev/null || sshd -T 2>/dev/null');
  if (sshdT) {
    const rootMatch = sshdT.match(/^permitrootlogin\s+([^\s]+)/mi);
    if (rootMatch) {
      const val = rootMatch[1].toLowerCase();
      if (val === 'yes' || val === 'prohibit-password' || val === 'no') {
        permitRootLogin = val;
      }
    }

    const passMatch = sshdT.match(/^passwordauthentication\s+([^\s]+)/mi);
    if (passMatch) {
      const val = passMatch[1].toLowerCase();
      if (val === 'yes' || val === 'no') {
        passwordAuthentication = val;
      }
    }

    const portMatch = sshdT.match(/^port\s+(\d+)/mi);
    if (portMatch) {
      listeningPort = parseInt(portMatch[1], 10);
    }

    sftpActive = /subsystem\s+sftp/i.test(sshdT);
  } else if (fs.existsSync('/etc/ssh/sshd_config')) {
    // Parse config directly if sshd -T isn't runnable
    try {
      const conf = fs.readFileSync('/etc/ssh/sshd_config', 'utf8');
      const rootMatch = conf.match(/^PermitRootLogin\s+([^\s]+)/mi);
      if (rootMatch) {
        const val = rootMatch[1].toLowerCase();
        if (val === 'yes' || val === 'prohibit-password' || val === 'no') {
          permitRootLogin = val;
        }
      }
      const passMatch = conf.match(/^PasswordAuthentication\s+([^\s]+)/mi);
      if (passMatch) {
        const val = passMatch[1].toLowerCase();
        if (val === 'yes' || val === 'no') {
          passwordAuthentication = val;
        }
      }
      const portMatch = conf.match(/^Port\s+(\d+)/mi);
      if (portMatch) {
        listeningPort = parseInt(portMatch[1], 10);
      }
      sftpActive = /^Subsystem\s+sftp/mi.test(conf);
    } catch {
      // ignore
    }
  }

  // Find configured users with authorized_keys
  const configuredUsers: string[] = [];
  try {
    if (fs.existsSync('/root/.ssh/authorized_keys')) {
      configuredUsers.push('root');
    }
    if (fs.existsSync('/home')) {
      const homeEntries = fs.readdirSync('/home');
      for (const user of homeEntries) {
        if (fs.existsSync(path.join('/home', user, '.ssh/authorized_keys'))) {
          configuredUsers.push(user);
        }
      }
    }
  } catch {
    // ignore
  }

  // Check saved user in state dir
  const savedUserFile = path.join(STATE_DIR, 'user');
  if (fs.existsSync(savedUserFile)) {
    try {
      const u = fs.readFileSync(savedUserFile, 'utf8').trim();
      if (u && !configuredUsers.includes(u)) configuredUsers.push(u);
    } catch {
      // ignore
    }
  }

  return {
    isInstalled,
    isRunning,
    version,
    listeningPort,
    pid,
    serviceMode,
    permitRootLogin,
    passwordAuthentication,
    sftpActive,
    configuredUsers,
    sshdConfigPath: '/etc/ssh/sshd_config'
  };
}

export function getTunnels(): TunnelInstance[] {
  const tunnels: TunnelInstance[] = [];
  const tunnelsDir = path.join(STATE_DIR, 'tunnels');

  if (fs.existsSync(tunnelsDir)) {
    try {
      const dirs = fs.readdirSync(tunnelsDir);
      for (const tunnelName of dirs) {
        const itemPath = path.join(tunnelsDir, tunnelName);
        if (!fs.statSync(itemPath).isDirectory()) continue;

        let name = tunnelName;
        let hostname: string | undefined;
        let domain: string | undefined;
        let pid: number | undefined;
        let logFile: string | undefined;
        let provider: 'cloudflared' | 'fxtunnel' = 'cloudflared';
        let tokenConfigured = false;

        const nameFile = path.join(itemPath, 'name');
        if (fs.existsSync(nameFile)) name = fs.readFileSync(nameFile, 'utf8').trim();

        const hostFile = path.join(itemPath, 'hostname');
        if (fs.existsSync(hostFile)) hostname = fs.readFileSync(hostFile, 'utf8').trim();

        const domainFile = path.join(itemPath, 'domain');
        if (fs.existsSync(domainFile)) domain = fs.readFileSync(domainFile, 'utf8').trim();

        const pidFile = path.join(itemPath, 'pid');
        if (fs.existsSync(pidFile)) {
          const rawPid = fs.readFileSync(pidFile, 'utf8').trim();
          if (rawPid) pid = parseInt(rawPid, 10);
        }

        const logPathFile = path.join(itemPath, 'log');
        if (fs.existsSync(logPathFile)) logFile = fs.readFileSync(logPathFile, 'utf8').trim();

        const tokenFile = path.join(itemPath, 'token');
        if (fs.existsSync(tokenFile)) {
          tokenConfigured = true;
          provider = 'fxtunnel';
        }

        let isRunning = false;
        let runMode: 'foreground' | 'background' | 'systemd' | 'unknown' = 'unknown';

        if (pid) {
          try {
            process.kill(pid, 0);
            isRunning = true;
            runMode = 'background';
          } catch {
            isRunning = false;
          }
        }

        // Check if systemd unit is active
        if (!isRunning && fs.existsSync('/run/systemd/system')) {
          const unit = provider === 'fxtunnel' ? `fxtunnel-${name}` : 'cloudflared';
          const active = safeExec(`systemctl is-active ${unit} 2>/dev/null`) === 'active';
          if (active) {
            isRunning = true;
            runMode = 'systemd';
          }
        }

        tunnels.push({
          name,
          provider,
          hostname,
          domain,
          targetPort: 22,
          pid,
          isRunning,
          runMode,
          logFile,
          tokenConfigured
        });
      }
    } catch {
      // ignore
    }
  }

  return tunnels;
}

export function getRecentLogs(limit = 100): LogEntry[] {
  const entries: LogEntry[] = [];
  try {
    // Find all setup-ssh-tunnel logs in /tmp
    const files = fs.readdirSync('/tmp').filter(f => f.startsWith('setup-ssh-tunnel-') && f.endsWith('.log'));
    // Sort newest first
    files.sort().reverse();

    for (const f of files.slice(0, 3)) {
      const fullPath = path.join('/tmp', f);
      const content = fs.readFileSync(fullPath, 'utf8');
      const lines = content.split('\n').filter(Boolean);
      for (const line of lines.slice(-limit)) {
        let level: 'info' | 'ok' | 'warn' | 'error' = 'info';
        if (line.includes('[OK]')) level = 'ok';
        else if (line.includes('[WARNING]')) level = 'warn';
        else if (line.includes('[ERROR]')) level = 'error';

        entries.push({
          id: `${f}-${Math.random().toString(36).substring(2, 8)}`,
          timestamp: new Date().toISOString(),
          level,
          source: 'install.sh',
          message: redactSecrets(line.replace(/\x1B\[[0-9;]*[a-zA-Z]/g, ''))
        });
      }
    }
  } catch {
    // ignore
  }

  return entries.slice(-limit);
}
