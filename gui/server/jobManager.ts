import { spawn, execSync, ChildProcess } from 'child_process';
import path from 'path';
import { JobState, JobStatus, JobType, LogEntry } from './types.js';
import { redactSecrets } from './systemService.js';
import { buildInvocation, findInstallScript } from './scriptService.js';
import { GUI_PORT } from './config.js';

const JOB_TIMEOUT_MS = 15 * 60 * 1000;

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
      source: entry.source || 'install.sh',
      message: redactSecrets(entry.message),
    };
    this.currentJob.logs.push(log);
    if (this.currentJob.logs.length > 1000) {
      this.currentJob.logs.shift();
    }
  }

  public validateParameters(type: JobType, params: Record<string, any>): { valid: boolean; error?: string } {
    // 1. Console port protection & range check. The port this Control Center
    // listens on must never be exposed through a tunnel.
    if (params.localPort !== undefined && params.localPort !== null && params.localPort !== '') {
      const port = Number(params.localPort);
      if (isNaN(port) || port < 1 || port > 65535) {
        return { valid: false, error: 'Port must be a valid integer between 1 and 65535.' };
      }
      if (port === GUI_PORT) {
        return {
          valid: false,
          error: `PROTECTED INFRASTRUCTURE: Port ${GUI_PORT} is reserved for this SSH.JC Control Center. Exposing or redirecting the console port is prohibited.`,
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
    if (params.provider === 'fxtunnel' && (type === 'configure_tunnel' || type === 'full_setup')) {
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

    // 7. sshd security directive values
    if (type === 'update_sshd_security') {
      const rootValues = ['yes', 'no', 'prohibit-password', 'forced-commands-only'];
      if (params.permitRootLogin !== undefined && !rootValues.includes(params.permitRootLogin)) {
        return { valid: false, error: `permitRootLogin must be one of: ${rootValues.join(', ')}.` };
      }
      if (params.passwordAuthentication !== undefined && !['yes', 'no'].includes(params.passwordAuthentication)) {
        return { valid: false, error: 'passwordAuthentication must be "yes" or "no".' };
      }
      if (params.permitRootLogin === undefined && params.passwordAuthentication === undefined) {
        return { valid: false, error: 'Provide permitRootLogin and/or passwordAuthentication.' };
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
      toggle_sftp: 'Toggle SFTP Subsystem',
    };

    // Never keep secrets in the job record echoed back through the API.
    const safeParams = { ...params };
    if (safeParams.fxToken) safeParams.fxToken = '***';

    const job: JobState = {
      id,
      type,
      title: titles[type] || type,
      status: 'preparing',
      startedAt: new Date().toISOString(),
      logs: [],
      parameters: safeParams,
      progressMessage: 'Validating environment and configuration...',
    };

    this.currentJob = job;
    this.runScriptJob(job, type, params).catch(err => {
      console.error(`[SSH.JC] Job runner error (${job.id}):`, err);
    });
    return job;
  }

  private async runScriptJob(job: JobState, type: JobType, params: Record<string, any>): Promise<void> {
    const invocation = buildInvocation(type, params);
    const scriptPath = invocation.scriptPath;

    job.status = 'running';
    job.progressMessage = `Running Install.sh (${type})`;
    this.addLog({
      level: 'info',
      message: `Executing Install.sh in non-interactive mode: ${invocation.summary}`,
    });

    const proc = spawn('bash', [scriptPath], {
      cwd: path.dirname(scriptPath),
      env: { ...process.env, ...invocation.env },
      detached: true, // own process group so cancel/timeout can kill children
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.currentProcess = proc;

    if (invocation.stdinAnswers.length > 0) {
      proc.stdin?.write(invocation.stdinAnswers.join('\n') + '\n');
    }
    proc.stdin?.end();

    const handleChunk = (chunk: Buffer) => {
      const text = chunk.toString('utf8');
      for (const rawLine of text.split('\n')) {
        const line = rawLine.replace(/\x1B\[[0-9;]*[a-zA-Z]/g, '').trim();
        if (!line) continue;
        let level: 'info' | 'ok' | 'warn' | 'error' = 'info';
        if (line.includes('[OK]')) level = 'ok';
        else if (line.includes('[WARNING]')) level = 'warn';
        else if (line.includes('[ERROR]')) level = 'error';
        this.addLog({ level, message: line });
        if (level === 'error') job.errorMessage = line.replace('[ERROR]', '').trim();
      }
    };
    proc.stdout?.on('data', handleChunk);
    proc.stderr?.on('data', handleChunk);

    const timeout = setTimeout(() => {
      this.addLog({ level: 'error', message: 'Job timed out (15 minutes). Terminating Install.sh.' });
      this.killProcessTree(proc);
    }, JOB_TIMEOUT_MS);

    const exitCode: number = await new Promise((resolve) => {
      proc.on('error', () => resolve(-1));
      proc.on('close', (code) => resolve(code ?? -1));
    });
    clearTimeout(timeout);
    this.currentProcess = null;

    job.finishedAt = new Date().toISOString();
    job.exitCode = exitCode;
    const statusNow = job.status as JobStatus;
    if (statusNow !== 'cancelled') {
      job.status = exitCode === 0 ? 'completed' : 'failed';
    }
    job.progressMessage = undefined;
    this.addLog({
      level: exitCode === 0 ? 'ok' : 'error',
      message: `Install.sh finished with exit code ${exitCode}.`,
    });

    this.jobHistory.push({ ...job, logs: [...job.logs] });
    if (this.jobHistory.length > 20) this.jobHistory.shift();
  }

  private killProcessTree(proc: ChildProcess): void {
    try {
      if (proc.pid) process.kill(-proc.pid, 'SIGTERM');
    } catch {
      try { proc.kill('SIGTERM'); } catch { /* already gone */ }
    }
    setTimeout(() => {
      try {
        if (proc.pid) process.kill(-proc.pid, 'SIGKILL');
      } catch {
        try { proc.kill('SIGKILL'); } catch { /* already gone */ }
      }
    }, 3000);
  }

  public cancelActiveJob(): boolean {
    if (!this.currentJob || !this.currentProcess) return false;
    if (this.currentJob.status !== 'running' && this.currentJob.status !== 'preparing') return false;
    this.currentJob.status = 'cancelled';
    this.addLog({ level: 'warn', message: 'Job cancelled by operator. Terminating Install.sh.' });
    this.killProcessTree(this.currentProcess);
    return true;
  }
}

export const jobManager = new JobManager();
export { findInstallScript };
