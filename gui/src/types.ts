export interface SshStatus {
  isInstalled: boolean;
  isRunning: boolean;
  version?: string;
  listeningPort: number;
  pid?: number;
  serviceMode: 'systemd' | 'standalone' | 'none';
  permitRootLogin: 'yes' | 'prohibit-password' | 'no' | 'unknown';
  passwordAuthentication: 'yes' | 'no' | 'unknown';
  sftpActive: boolean;
  configuredUsers: string[];
  sshdConfigPath: string;
}

export interface TunnelInstance {
  name: string;
  provider: 'cloudflared' | 'fxtunnel';
  hostname?: string;
  domain?: string;
  targetPort: number;
  pid?: number;
  isRunning: boolean;
  runMode: 'foreground' | 'background' | 'systemd' | 'unknown';
  logFile?: string;
  tokenConfigured?: boolean;
}

export interface ProtectedInfrastructure {
  port: number;
  process: string;
  pid?: number;
  isLocked: boolean;
  reason: string;
  allowedOrigins: string[];
  alertMessage?: string;
}

export interface SystemInfo {
  osName: string;
  distroId: string;
  architecture: string;
  hasSystemd: boolean;
  hasSudo: boolean;
  isRoot: boolean;
  cloudflaredInstalled: boolean;
  cloudflaredVersion?: string;
  fxtunnelInstalled: boolean;
  fxtunnelVersion?: string;
  jqInstalled: boolean;
  stateDir: string;
  activeProvider: 'cloudflared' | 'fxtunnel' | 'none';
  protectedInfra: ProtectedInfrastructure;
}

export interface LogEntry {
  id: string;
  timestamp: string;
  level: 'info' | 'ok' | 'warn' | 'error';
  source: string;
  message: string;
}

export type JobType = 
  | 'full_setup'
  | 'install_openssh'
  | 'install_tunnel_client'
  | 'configure_tunnel'
  | 'run_tunnel'
  | 'stop_tunnel'
  | 'configure_admin_user'
  | 'update_sshd_security'
  | 'toggle_sftp';

export type JobStatus = 'idle' | 'preparing' | 'running' | 'completed' | 'failed' | 'cancelled';

export interface JobState {
  id: string;
  type: JobType;
  title: string;
  status: JobStatus;
  startedAt: string;
  finishedAt?: string;
  exitCode?: number;
  progressMessage?: string;
  logs: LogEntry[];
  parameters: Record<string, any>;
  errorMessage?: string;
}

export interface SystemStatusResponse {
  system: SystemInfo;
  ssh: SshStatus;
  tunnels: TunnelInstance[];
  protectedInfra: ProtectedInfrastructure;
  activeJob: JobState | null;
}
