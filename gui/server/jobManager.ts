import { spawn, execSync, ChildProcess } from 'child_process';
import fs from 'fs';
import path from 'path';
import { JobState, JobType, LogEntry } from './types.js';
import { redactSecrets } from './systemService.js';

const HOME_DIR = process.env.HOME || '/root';
const STATE_DIR = path.join(HOME_DIR, '.setup-ssh-tunnel');

class JobManager {
  private currentJob: JobState | null = null;
  private currentProcess: ChildProcess | null = null;
  private jobHistory: JobState[] = [];

  public hasBinary(bin: string): boolean {
    try {
      const out = execSync(`which ${bin} 2>/dev/null`, { encoding: 'utf8' }).trim();
      return Boolean(out);
    } catch {
      return false;
    }
  }

  public getActiveJob(): JobState | null {
    return this.currentJob;
  }

  public getJob(id: string): JobState | null {
    if (this.currentJob?.id === id) return this.currentJob;
    return this.jobHistory.find(j => j.id === id) || null;
  }

  public getHistory(): JobState[] {
    return this.jobHistory.slice(-20);
  }

  private addLog(entry: { level: 'info' | 'ok' | 'warn' | 'error'; message: string; source?: string }) {
    if (!this.currentJob) return;
    const log: LogEntry = {
      id: `${Date.now()}-${Math.random().toString(36).substring(2, 6)}`,
      timestamp: new Date().toISOString(),
      level: entry.level,
      source: entry.source || 'executor',
      message: redactSecrets(entry.message)
    };
    this.currentJob.logs.push(log);
    // Keep max 1000 logs in memory
    if (this.currentJob.logs.length > 1000) {
      this.currentJob.logs.shift();
    }
  }

  public validateParameters(type: JobType, params: Record<string, any>): { valid: boolean; error?: string } {
    // 1. Port 3000 Protection & Range Check
    if (params.localPort !== undefined && params.localPort !== null && params.localPort !== '') {
      const port = Number(params.localPort);
      if (isNaN(port) || port < 1 || port > 65535) {
        return { valid: false, error: 'Port must be a valid integer between 1 and 65535.' };
      }
      if (port === 3000) {
        return {
          valid: false,
          error: 'PROTECTED INFRASTRUCTURE: Port 3000 is reserved for AI Studio and the existing Cloudflare tunnel. Exposing or redirecting port 3000 is prohibited.'
        };
      }
    }

    // 2. Tunnel Name Validation
    if (params.tunnelName) {
      if (!/^[a-zA-Z0-9_-]{1,64}$/.test(params.tunnelName)) {
        return { valid: false, error: 'Tunnel name must contain only alphanumeric characters, dashes, or underscores (1-64 chars).' };
      }
    }

    // 3. Domain & Subdomain Validation
    if (params.domain) {
      if (!/^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/.test(params.domain)) {
        return { valid: false, error: 'Invalid domain format. Example: example.com or dpdns.org' };
      }
    }

    if (params.subdomain) {
      if (!/^[a-zA-Z0-9_-]{0,64}$/.test(params.subdomain)) {
        return { valid: false, error: 'Subdomain must contain only alphanumeric characters, dashes, or underscores.' };
      }
    }

    // 4. fxTunnel Token Validation
    if (params.provider === 'fxtunnel' && type === 'configure_tunnel') {
      if (!params.fxToken || typeof params.fxToken !== 'string' || !params.fxToken.startsWith('sk_')) {
        return { valid: false, error: 'fxTunnel requires a valid API token starting with "sk_".' };
      }
    }

    // 5. Username Validation
    if (params.username) {
      if (!/^[a-z_][a-z0-9_-]{0,31}$/.test(params.username)) {
        return { valid: false, error: 'Invalid username format. Must begin with lowercase letter or underscore.' };
      }
    }

    // 6. Public Key Format Validation
    if (params.pubkey) {
      const validKeyRegex = /^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+[A-Za-z0-9+/]+={0,3}(\s+.*)?$/;
      if (!validKeyRegex.test(params.pubkey.trim())) {
        return { valid: false, error: 'Invalid SSH public key format. Expected OpenSSH key starting with ssh-rsa, ssh-ed25519, etc.' };
      }
    }

    return { valid: true };
  }

  public async startJob(type: JobType, params: Record<string, any>): Promise<JobState> {
    if (this.currentJob && (this.currentJob.status === 'running' || this.currentJob.status === 'preparing')) {
      throw new Error(`Another job (${this.currentJob.title}) is currently active. Please wait or cancel it first.`);
    }

    const validation = this.validateParameters(type, params);
    if (!validation.valid) {
      throw new Error(validation.error || 'Validation failed.');
    }

    const id = `job_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`;
    const titles: Record<JobType, string> = {
      full_setup: 'Full SSH + Cloudflare / fxTunnel Setup',
      install_openssh: 'Install & Configure OpenSSH Server',
      install_tunnel_client: `Install Tunnel Client (${params.provider || 'cloudflared'})`,
      configure_tunnel: `Configure Tunnel (${params.tunnelName || 'ssh-sandbox'})`,
      run_tunnel: `Launch Tunnel (${params.tunnelName || 'ssh-sandbox'}) on Port ${params.localPort || 22}`,
      stop_tunnel: `Stop Tunnel (${params.tunnelName || 'Active Tunnel'})`,
      configure_admin_user: `Create Admin User (${params.username || 'admin'})`,
      update_sshd_security: 'Update SSH Security Directives',
      toggle_sftp: 'Toggle SFTP Subsystem'
    };

    const job: JobState = {
      id,
      type,
      title: titles[type] || type,
      status: 'preparing',
      startedAt: new Date().toISOString(),
      logs: [],
      parameters: { ...params },
      progressMessage: 'Validating environment and configuration...'
    };

    this.currentJob = job;

    // Run execution asynchronously
    this.runJobProcess(job).catch(err => {
      job.status = 'failed';
      job.errorMessage = err.message;
      job.finishedAt = new Date().toISOString();
      this.addLog({ level: 'error', message: `Execution failed: ${err.message}` });
      this.finishJob();
    });

    return job;
  }

  public cancelActiveJob(): boolean {
    if (!this.currentJob || this.currentJob.status !== 'running') {
      return false;
    }
    this.addLog({ level: 'warn', message: 'Received cancellation request from operator. Terminating process...' });
    this.currentJob.status = 'cancelled';
    this.currentJob.progressMessage = 'Operation cancelled by user';
    this.currentJob.finishedAt = new Date().toISOString();

    if (this.currentProcess) {
      this.currentProcess.kill('SIGTERM');
      setTimeout(() => {
        if (this.currentProcess && !this.currentProcess.killed) {
          this.currentProcess.kill('SIGKILL');
        }
      }, 3000);
    }

    this.finishJob();
    return true;
  }

  private finishJob() {
    if (this.currentJob) {
      this.jobHistory.push(this.currentJob);
      this.currentJob = null;
    }
    this.currentProcess = null;
  }

  private async runJobProcess(job: JobState): Promise<void> {
    job.status = 'running';
    this.addLog({ level: 'info', message: `Starting task: ${job.title}` });

    // Execute verified backend operations
    switch (job.type) {
      case 'install_openssh':
        await this.executeInstallOpenSSH(job);
        break;
      case 'install_tunnel_client':
        await this.executeInstallTunnelClient(job);
        break;
      case 'configure_tunnel':
        await this.executeConfigureTunnel(job);
        break;
      case 'run_tunnel':
        await this.executeRunTunnel(job);
        break;
      case 'stop_tunnel':
        await this.executeStopTunnel(job);
        break;
      case 'configure_admin_user':
        await this.executeConfigureAdminUser(job);
        break;
      case 'update_sshd_security':
        await this.executeUpdateSshdSecurity(job);
        break;
      case 'toggle_sftp':
        await this.executeToggleSftp(job);
        break;
      case 'full_setup':
        await this.executeFullSetup(job);
        break;
      default:
        throw new Error(`Unsupported operation type: ${job.type}`);
    }

    job.status = 'completed';
    job.exitCode = 0;
    job.finishedAt = new Date().toISOString();
    job.progressMessage = 'Operation completed successfully.';
    this.addLog({ level: 'ok', message: `${job.title} succeeded.` });
    this.finishJob();
  }

  private async executeCommand(
    command: string,
    args: string[],
    job: JobState,
    env?: NodeJS.ProcessEnv
  ): Promise<number> {
    return new Promise((resolve, reject) => {
      this.addLog({ level: 'info', message: `Executing: ${command} ${args.join(' ')}` });

      const child = spawn(command, args, {
        env: { ...process.env, ...env },
        stdio: ['pipe', 'pipe', 'pipe']
      });

      this.currentProcess = child;

      child.stdout.on('data', data => {
        const lines = data.toString().split('\n').filter(Boolean);
        for (const line of lines) {
          this.addLog({ level: 'info', message: line, source: command });
        }
      });

      child.stderr.on('data', data => {
        const lines = data.toString().split('\n').filter(Boolean);
        for (const line of lines) {
          this.addLog({ level: 'warn', message: line, source: command });
        }
      });

      child.on('error', err => {
        this.addLog({ level: 'error', message: `Process error: ${err.message}` });
        reject(err);
      });

      child.on('close', code => {
        if (code === 0) {
          resolve(0);
        } else {
          this.addLog({ level: 'error', message: `Process exited with code ${code}` });
          reject(new Error(`Command ${command} exited with code ${code}`));
        }
      });
    });
  }

  private async executeInstallOpenSSH(job: JobState): Promise<void> {
    job.progressMessage = 'Installing OpenSSH server package...';
    try {
      await this.executeCommand('apt-get', ['update', '-y'], job);
      await this.executeCommand('apt-get', ['install', '-y', 'openssh-server'], job);
    } catch {
      this.addLog({ level: 'warn', message: 'Apt install encountered an issue, checking existing sshd...' });
    }

    // Ensure /run/sshd exists
    if (!fs.existsSync('/run/sshd')) {
      fs.mkdirSync('/run/sshd', { recursive: true });
    }

    // Start sshd if not running
    try {
      if (fs.existsSync('/run/systemd/system')) {
        await this.executeCommand('systemctl', ['enable', '--now', 'ssh'], job);
      } else {
        await this.executeCommand('/usr/sbin/sshd', [], job);
      }
    } catch {
      this.addLog({ level: 'info', message: 'sshd start attempt completed or already active.' });
    }
  }

  private async executeInstallTunnelClient(job: JobState): Promise<void> {
    const provider = job.parameters.provider || 'cloudflared';
    if (provider === 'fxtunnel') {
      job.progressMessage = 'Downloading fxTunnel client...';
      const tmpScript = path.join('/tmp', `fxtunnel-install-${Date.now()}.sh`);
      await this.executeCommand('curl', ['-fsSL', 'https://fxtun.dev/install.sh', '-o', tmpScript], job);
      await this.executeCommand('sh', [tmpScript], job);
      try { fs.unlinkSync(tmpScript); } catch {}
    } else {
      job.progressMessage = 'Downloading cloudflared debian package...';
      const arch = 'amd64';
      const tmpDeb = path.join('/tmp', `cloudflared-${Date.now()}.deb`);
      const url = `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb`;
      await this.executeCommand('curl', ['-fL', '-o', tmpDeb, url], job);
      await this.executeCommand('dpkg', ['-i', tmpDeb], job);
      try { fs.unlinkSync(tmpDeb); } catch {}
    }

    // Save provider to state
    this.saveState('provider', provider);
  }

  private async executeConfigureTunnel(job: JobState): Promise<void> {
    const { tunnelName, provider, fxToken, domain, subdomain } = job.parameters;
    const resolvedTunnelName = tunnelName || 'ssh-sandbox';

    if (provider === 'fxtunnel') {
      job.progressMessage = `Saving fxTunnel configuration for ${resolvedTunnelName}...`;
      this.saveTunnelState(resolvedTunnelName, 'name', resolvedTunnelName);
      this.saveTunnelState(resolvedTunnelName, 'token', fxToken);
      this.saveState('provider', 'fxtunnel');
      this.addLog({ level: 'ok', message: `fxTunnel token registered for '${resolvedTunnelName}'.` });
    } else {
      job.progressMessage = `Configuring Cloudflare tunnel: ${resolvedTunnelName}...`;
      try {
        await this.executeCommand('cloudflared', ['tunnel', 'create', resolvedTunnelName], job);
      } catch (e) {
        this.addLog({ level: 'warn', message: `Tunnel may already exist or required login: ${(e as Error).message}` });
      }

      if (domain) {
        const fullHost = subdomain ? `${subdomain}.${domain}` : domain;
        job.progressMessage = `Routing DNS ${fullHost} -> ${resolvedTunnelName}...`;
        try {
          await this.executeCommand('cloudflared', ['tunnel', 'route', 'dns', resolvedTunnelName, fullHost], job);
        } catch {
          this.addLog({ level: 'warn', message: 'DNS route command logged; verify route existence in Cloudflare dashboard.' });
        }
        this.saveTunnelState(resolvedTunnelName, 'hostname', fullHost);
        this.saveTunnelState(resolvedTunnelName, 'domain', domain);
      }

      this.saveTunnelState(resolvedTunnelName, 'name', resolvedTunnelName);
      this.saveState('provider', 'cloudflared');
    }
  }

  private async executeRunTunnel(job: JobState): Promise<void> {
    const { tunnelName, localPort = 22, runMode = 'background', provider } = job.parameters;
    const resolvedPort = Number(localPort);

    // Hard safeguard check
    if (resolvedPort === 3000) {
      throw new Error('SAFEGUARD TRIGGERED: Port 3000 is strictly protected.');
    }

    const resolvedTunnelName = tunnelName || 'ssh-sandbox';
    job.progressMessage = `Starting tunnel '${resolvedTunnelName}' targeting local port ${resolvedPort}...`;

    if (runMode === 'systemd' && fs.existsSync('/run/systemd/system')) {
      if (provider === 'fxtunnel') {
        const unitName = `fxtunnel-${resolvedTunnelName}`;
        await this.executeCommand('systemctl', ['enable', '--now', unitName], job);
      } else {
        await this.executeCommand('systemctl', ['enable', '--now', 'cloudflared'], job);
      }
      this.addLog({ level: 'ok', message: `Systemd service started for tunnel '${resolvedTunnelName}'.` });
    } else {
      // Background process
      const logPath = `/tmp/tunnel-${resolvedTunnelName}-${Date.now()}.log`;
      let cmd: string;
      let args: string[];

      if (provider === 'fxtunnel') {
        const token = this.getTunnelState(resolvedTunnelName, 'token') || job.parameters.fxToken;
        if (!token) {
          throw new Error(`fxTunnel requires an account token. Please configure the tunnel with an API token first.`);
        }
        cmd = 'fxtunnel';
        args = ['tcp', String(resolvedPort), '-t', token];
      } else {
        cmd = 'cloudflared';
        args = ['tunnel', 'run', '--url', `ssh://localhost:${resolvedPort}`, resolvedTunnelName];
      }

      // Verify binary is actually installed before attempting to spawn
      if (!this.hasBinary(cmd)) {
        throw new Error(
          `The tunnel client binary '${cmd}' is not installed on this system. Please install ${cmd} first (Wizard Option 3) before launching a tunnel.`
        );
      }

      const logStream = fs.openSync(logPath, 'a');
      await new Promise<void>((resolve, reject) => {
        let spawned = false;
        const child = spawn(cmd, args, {
          detached: true,
          stdio: ['ignore', logStream, logStream]
        });

        // Always handle 'error' event to prevent unhandled node exceptions (e.g. ENOENT)
        child.on('error', (err) => {
          this.addLog({ level: 'error', message: `Tunnel process failed to spawn: ${err.message}` });
          reject(new Error(`Failed to spawn ${cmd}: ${err.message}`));
        });

        // Allow a brief settling delay to ensure spawn didn't error immediately
        setTimeout(() => {
          if (child.pid && !child.killed) {
            spawned = true;
            child.unref();
            this.saveTunnelState(resolvedTunnelName, 'pid', String(child.pid));
            this.saveTunnelState(resolvedTunnelName, 'log', logPath);
            this.addLog({ level: 'ok', message: `Tunnel started in background (PID: ${child.pid}). Log: ${logPath}` });
            resolve();
          } else if (!spawned) {
            resolve();
          }
        }, 150);
      });
    }
  }

  private async executeStopTunnel(job: JobState): Promise<void> {
    const { tunnelName } = job.parameters;
    const pidStr = this.getTunnelState(tunnelName, 'pid');
    if (pidStr) {
      const pid = parseInt(pidStr, 10);
      try {
        process.kill(pid, 'SIGTERM');
        this.addLog({ level: 'ok', message: `Stopped tunnel process (PID: ${pid}).` });
      } catch (e) {
        this.addLog({ level: 'warn', message: `Could not terminate PID ${pid}: ${(e as Error).message}` });
      }
    }

    if (fs.existsSync('/run/systemd/system')) {
      try {
        await this.executeCommand('systemctl', ['stop', `fxtunnel-${tunnelName}`], job);
      } catch {}
      try {
        await this.executeCommand('systemctl', ['stop', 'cloudflared'], job);
      } catch {}
    }
  }

  private async executeConfigureAdminUser(job: JobState): Promise<void> {
    const { username = 'admin', pubkey, disablePasswordAuth } = job.parameters;

    job.progressMessage = `Creating administrative user '${username}'...`;
    try {
      await this.executeCommand('useradd', ['-m', '-s', '/bin/bash', '-G', 'sudo', username], job);
    } catch {
      this.addLog({ level: 'info', message: `User '${username}' already exists or was updated.` });
    }

    if (pubkey) {
      const userSshDir = path.join('/home', username, '.ssh');
      const authKeysPath = path.join(userSshDir, 'authorized_keys');

      if (!fs.existsSync(userSshDir)) {
        fs.mkdirSync(userSshDir, { recursive: true, mode: 0o700 });
      }

      // Key deduplication logic from Install.sh
      let existingKeys = '';
      if (fs.existsSync(authKeysPath)) {
        existingKeys = fs.readFileSync(authKeysPath, 'utf8');
      }

      if (!existingKeys.includes(pubkey.trim())) {
        fs.appendFileSync(authKeysPath, `${pubkey.trim()}\n`, { mode: 0o600 });
        this.addLog({ level: 'ok', message: `Appended public key to ${authKeysPath}` });
      } else {
        this.addLog({ level: 'info', message: `Public key already present in ${authKeysPath}, skipped duplicate.` });
      }
    }

    if (disablePasswordAuth) {
      await this.executeUpdateSshdSecurity(job, { passwordAuth: 'no' });
    }

    this.saveState('user', username);
  }

  private async executeUpdateSshdSecurity(job: JobState, overrideOpts?: { passwordAuth?: string; permitRoot?: string }): Promise<void> {
    const sshdConfig = '/etc/ssh/sshd_config';
    if (!fs.existsSync(sshdConfig)) {
      this.addLog({ level: 'warn', message: 'sshd_config not present, skipping modification.' });
      return;
    }

    // Always create a backup first
    const backupPath = `/etc/ssh/sshd_config.bak.${Date.now()}`;
    fs.copyFileSync(sshdConfig, backupPath);
    this.addLog({ level: 'info', message: `Created backup at ${backupPath}` });

    let content = fs.readFileSync(sshdConfig, 'utf8');

    const passAuth = overrideOpts?.passwordAuth || job.parameters.passwordAuthentication;
    if (passAuth === 'no' || passAuth === 'yes') {
      content = content.replace(/^#?\s*PasswordAuthentication\s+.*$/m, `PasswordAuthentication ${passAuth}`);
      this.addLog({ level: 'ok', message: `Set PasswordAuthentication to '${passAuth}'.` });
    }

    const permitRoot = overrideOpts?.permitRoot || job.parameters.permitRootLogin;
    if (permitRoot) {
      content = content.replace(/^#?\s*PermitRootLogin\s+.*$/m, `PermitRootLogin ${permitRoot}`);
      this.addLog({ level: 'ok', message: `Set PermitRootLogin to '${permitRoot}'.` });
    }

    fs.writeFileSync(sshdConfig, content, 'utf8');

    // Validate syntax with sshd -t
    try {
      await this.executeCommand('sshd', ['-t'], job);
      this.addLog({ level: 'ok', message: 'sshd_config syntax validated successfully (sshd -t).' });
    } catch {
      this.addLog({ level: 'error', message: 'Syntax error detected in sshd_config! Restoring backup...' });
      fs.copyFileSync(backupPath, sshdConfig);
      throw new Error('sshd_config syntax validation failed; restored original configuration.');
    }
  }

  private async executeToggleSftp(job: JobState): Promise<void> {
    const sshdConfig = '/etc/ssh/sshd_config';
    if (!fs.existsSync(sshdConfig)) return;

    let content = fs.readFileSync(sshdConfig, 'utf8');
    const sftpCandidate = '/usr/lib/openssh/sftp-server';

    if (!/Subsystem\s+sftp/i.test(content)) {
      content += `\nSubsystem sftp ${sftpCandidate}\n`;
      fs.writeFileSync(sshdConfig, content, 'utf8');
      this.addLog({ level: 'ok', message: 'SFTP subsystem directive added to sshd_config.' });
    } else {
      this.addLog({ level: 'info', message: 'SFTP subsystem already active.' });
    }
  }

  private async executeFullSetup(job: JobState): Promise<void> {
    job.progressMessage = 'Step 1/5: Installing and starting OpenSSH server...';
    await this.executeInstallOpenSSH(job);

    if (job.parameters.username) {
      job.progressMessage = 'Step 2/5: Configuring administrative SSH user...';
      await this.executeConfigureAdminUser(job);
    }

    job.progressMessage = 'Step 3/5: Installing tunnel client...';
    await this.executeInstallTunnelClient(job);

    job.progressMessage = 'Step 4/5: Configuring tunnel and routing...';
    await this.executeConfigureTunnel(job);

    job.progressMessage = 'Step 5/5: Launching tunnel service...';
    await this.executeRunTunnel(job);
  }

  private saveState(key: string, val: string) {
    try {
      fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
      fs.writeFileSync(path.join(STATE_DIR, key), val, { mode: 0o600 });
    } catch {}
  }

  private saveTunnelState(tunnel: string, key: string, val: string) {
    try {
      const dir = path.join(STATE_DIR, 'tunnels', tunnel);
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      fs.writeFileSync(path.join(dir, key), val, { mode: 0o600 });
      fs.writeFileSync(path.join(STATE_DIR, 'last_tunnel'), tunnel, { mode: 0o600 });
    } catch {}
  }

  private getTunnelState(tunnel: string, key: string): string | null {
    try {
      const p = path.join(STATE_DIR, 'tunnels', tunnel, key);
      if (fs.existsSync(p)) return fs.readFileSync(p, 'utf8').trim();
    } catch {}
    return null;
  }
}

export const jobManager = new JobManager();
