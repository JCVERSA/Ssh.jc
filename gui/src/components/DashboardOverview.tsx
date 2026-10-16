import React from 'react';
import { motion } from 'motion/react';
import {
  Server,
  Globe,
  Cpu,
  ArrowRight,
  Activity,
  XOctagon,
  Lock,
  Zap,
  RotateCw
} from 'lucide-react';
import { SystemStatusResponse, JobState } from '../types';
import { TopologyMap } from './TopologyMap';
import { GlassCard } from './ui/GlassCard';
import { Button } from './ui/Button';
import {
  CyberKeyholeIcon,
  TunnelConduitIcon,
  BastionShieldIcon,
  PortGuardIcon,
  TelemetryRadarIcon
} from './ui/Icons';

interface DashboardOverviewProps {
  status: SystemStatusResponse;
  onNavigate: (tab: string) => void;
  onRefresh: () => void;
  isRefreshing: boolean;
  onCancelJob: (id: string) => void;
  onSelectTopologyNode: (nodeType: 'client' | 'ingress' | 'safeguard' | 'daemon', data?: any) => void;
}

export const DashboardOverview: React.FC<DashboardOverviewProps> = ({
  status,
  onNavigate,
  onRefresh,
  isRefreshing,
  onCancelJob,
  onSelectTopologyNode
}) => {
  const { system, ssh, tunnels, activeJob } = status;
  const activeTunnels = tunnels.filter((t) => t.isRunning);
  const primaryTunnel = tunnels[0];

  return (
    <div className="space-y-6">
      {/* 1. Hero Focal Point: Interactive Live Topology Map */}
      <motion.div
        initial={{ opacity: 0, y: 10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.3 }}
      >
        <TopologyMap status={status} onSelectNode={onSelectTopologyNode} />
      </motion.div>

      {/* 2. Active Job Tracker (if currently running) */}
      {activeJob && (
        <motion.div
          initial={{ opacity: 0, scale: 0.98 }}
          animate={{ opacity: 1, scale: 1 }}
        >
          <GlassCard
            variant="accent"
            className="p-4"
          >
            <div className="flex items-start justify-between gap-4">
              <div className="flex items-center gap-3.5">
                <div className="w-10 h-10 rounded bg-[#030d18] border border-[#00e5ff] flex items-center justify-center text-[#00e5ff] shrink-0 shadow-[0_0_12px_rgba(0,229,255,0.3)]">
                  <Activity className="w-5 h-5 animate-spin" />
                </div>
                <div>
                  <div className="flex items-center gap-2">
                    <span className="text-xs font-mono uppercase text-[#00e5ff] font-semibold tracking-wide">
                      OPERATION IN PROGRESS: {activeJob.type}
                    </span>
                    <span className="text-[10px] font-mono px-2 py-0.5 bg-[#030d18] border border-[#1e334a] text-[#b5c7d8] rounded font-semibold">
                      LIVE HOST
                    </span>
                  </div>
                  <h3 className="text-sm font-semibold text-[#e6f1fc] mt-0.5">{activeJob.title}</h3>
                  <p className="text-xs font-mono text-[#b5c7d8] mt-1">{activeJob.progressMessage || 'Processing system directives...'}</p>
                </div>
              </div>

              <Button
                variant="destructive"
                size="sm"
                onClick={() => onCancelJob(activeJob.id)}
                leftIcon={<XOctagon className="w-3.5 h-3.5" />}
              >
                Cancel Task
              </Button>
            </div>
          </GlassCard>
        </motion.div>
      )}

      {/* 3. Four Precision Telemetry Cards with Sleek Modern Glass */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        {/* OpenSSH Daemon */}
        <GlassCard
          variant="default"
          className="p-4 flex flex-col justify-between transition-all hover:border-[#00e5ff]/40 shadow-sm"
        >
          <div>
            <div className="flex items-center justify-between">
              <span className="text-xs font-mono text-[#7891a8] uppercase tracking-wider">SSH Service</span>
              <div className="w-7 h-7 rounded bg-[#112234] border border-[#1e334a] flex items-center justify-center text-[#38bdf8]">
                <BastionShieldIcon size={16} />
              </div>
            </div>
            <div className="mt-3 flex items-center gap-2">
              <span
                className={`w-2 h-2 rounded-full ${
                  ssh.isRunning ? 'bg-[#10b981] animate-pulse' : ssh.isInstalled ? 'bg-[#f59e0b]' : 'bg-[#ef4444]'
                }`}
              />
              <span className="text-base font-semibold text-[#e6f1fc]">
                {ssh.isRunning ? 'Running' : ssh.isInstalled ? 'Stopped' : 'Not Installed'}
              </span>
            </div>
            <div className="mt-2 text-xs font-mono text-[#b5c7d8] space-y-1">
              <div>Port: <span className="text-[#00e5ff] font-semibold">{ssh.listeningPort}</span> (TCP)</div>
              <div>Mode: <span className="text-[#e6f1fc]">{ssh.serviceMode}</span></div>
              <div>SFTP: <span className={ssh.sftpActive ? 'text-[#10b981] font-semibold' : 'text-[#7891a8]'}>{ssh.sftpActive ? 'Enabled' : 'Disabled'}</span></div>
            </div>
          </div>
          <button
            onClick={() => onNavigate('ssh')}
            className="mt-4 pt-3 border-t border-[#1e334a] flex items-center justify-between text-xs text-[#00e5ff] hover:text-[#38bdf8] font-medium transition-colors cursor-pointer"
          >
            <span>Manage Access & Keys</span>
            <ArrowRight className="w-3 h-3" />
          </button>
        </GlassCard>

        {/* Tunnel Ingress Client */}
        <GlassCard
          variant="default"
          className="p-4 flex flex-col justify-between transition-all hover:border-[#00e5ff]/40 shadow-sm"
        >
          <div>
            <div className="flex items-center justify-between">
              <span className="text-xs font-mono text-[#7891a8] uppercase tracking-wider">Tunnel Client</span>
              <div className="w-7 h-7 rounded bg-[#112234] border border-[#1e334a] flex items-center justify-center text-[#00e5ff]">
                <TunnelConduitIcon size={16} />
              </div>
            </div>
            <div className="mt-3 flex items-center gap-2">
              <span
                className={`w-2 h-2 rounded-full ${
                  system.cloudflaredInstalled || system.fxtunnelInstalled ? 'bg-[#10b981]' : 'bg-[#7891a8]'
                }`}
              />
              <span className="text-base font-semibold text-[#e6f1fc]">
                {system.cloudflaredInstalled
                  ? 'cloudflared'
                  : system.fxtunnelInstalled
                  ? 'fxTunnel'
                  : 'Uninstalled'}
              </span>
            </div>
            <div className="mt-2 text-xs font-mono text-[#b5c7d8] space-y-1">
              <div>Cloudflare: <span className={system.cloudflaredInstalled ? 'text-[#10b981] font-semibold' : 'text-[#7891a8]'}>{system.cloudflaredInstalled ? 'Installed' : 'No'}</span></div>
              <div>fxTunnel: <span className={system.fxtunnelInstalled ? 'text-[#10b981] font-semibold' : 'text-[#7891a8]'}>{system.fxtunnelInstalled ? 'Installed' : 'No'}</span></div>
              <div>Provider: <span className="text-[#00e5ff] font-semibold uppercase">{system.activeProvider}</span></div>
            </div>
          </div>
          <button
            onClick={() => onNavigate('wizard')}
            className="mt-4 pt-3 border-t border-[#1e334a] flex items-center justify-between text-xs text-[#00e5ff] hover:text-[#38bdf8] font-medium transition-colors cursor-pointer"
          >
            <span>Install / Switch Client</span>
            <ArrowRight className="w-3 h-3" />
          </button>
        </GlassCard>

        {/* Active Ingress Status */}
        <GlassCard
          variant="default"
          className="p-4 flex flex-col justify-between transition-all hover:border-[#00e5ff]/40 shadow-sm"
        >
          <div>
            <div className="flex items-center justify-between">
              <span className="text-xs font-mono text-[#7891a8] uppercase tracking-wider">Active Ingress</span>
              <div className="w-7 h-7 rounded bg-[#112234] border border-[#1e334a] flex items-center justify-center text-[#10b981]">
                <Globe className="w-4 h-4" />
              </div>
            </div>
            <div className="mt-3 flex items-center gap-2">
              <span
                className={`w-2 h-2 rounded-full ${activeTunnels.length > 0 ? 'bg-[#10b981] animate-pulse' : 'bg-[#7891a8]'}`}
              />
              <span className="text-base font-semibold text-[#e6f1fc]">
                {activeTunnels.length > 0 ? `${activeTunnels.length} Tunnel Active` : 'No Active Ingress'}
              </span>
            </div>
            <div className="mt-2 text-xs font-mono text-[#b5c7d8] space-y-1">
              <div className="truncate">
                Host: <span className="text-[#00e5ff] font-semibold">{primaryTunnel?.hostname || 'Not configured'}</span>
              </div>
              <div>Domain: <span className="text-[#e6f1fc]">{primaryTunnel?.domain || 'None'}</span></div>
              <div>PID: <span className="text-[#e6f1fc]">{primaryTunnel?.pid || 'None'}</span></div>
            </div>
          </div>
          <button
            onClick={() => onNavigate('tunnels')}
            className="mt-4 pt-3 border-t border-[#1e334a] flex items-center justify-between text-xs text-[#00e5ff] hover:text-[#38bdf8] font-medium transition-colors cursor-pointer"
          >
            <span>Inspect Tunnels</span>
            <ArrowRight className="w-3 h-3" />
          </button>
        </GlassCard>

        {/* Host Container Runtime */}
        <GlassCard
          variant="default"
          className="p-4 flex flex-col justify-between transition-all hover:border-[#00e5ff]/40 shadow-sm"
        >
          <div>
            <div className="flex items-center justify-between">
              <span className="text-xs font-mono text-[#7891a8] uppercase tracking-wider">Host Runtime</span>
              <div className="w-7 h-7 rounded bg-[#112234] border border-[#1e334a] flex items-center justify-center text-[#b5c7d8]">
                <Cpu className="w-4 h-4" />
              </div>
            </div>
            <div className="mt-3 flex items-center gap-2">
              <span className="w-2 h-2 rounded-full bg-[#10b981]" />
              <span className="text-base font-semibold text-[#e6f1fc] truncate">
                {system.osName.replace('Debian GNU/Linux', 'Debian')}
              </span>
            </div>
            <div className="mt-2 text-xs font-mono text-[#b5c7d8] space-y-1">
              <div>Arch: <span className="text-[#e6f1fc] font-semibold">{system.architecture}</span></div>
              <div>Systemd: <span className={system.hasSystemd ? 'text-[#10b981]' : 'text-[#f59e0b]'}>{system.hasSystemd ? 'Available' : 'Container (nohup)'}</span></div>
              <div>Privilege: <span className="text-[#10b981] font-semibold">{system.isRoot ? 'root' : 'sudo'}</span></div>
            </div>
          </div>
          <div className="mt-4 pt-3 border-t border-[#1e334a] flex items-center justify-between text-xs text-[#7891a8] font-mono">
            <span>State: ~/.setup-ssh-tunnel</span>
          </div>
        </GlassCard>
      </div>

      {/* 4. Verified Capabilities Grid & Security Directives */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left 2 Cols: Capabilities Launcher */}
        <GlassCard variant="default" className="lg:col-span-2 space-y-4">
          <div className="flex items-center justify-between border-b border-[#1e334a] pb-3">
            <div>
              <h2 className="text-sm font-semibold text-[#e6f1fc]">Install.sh Verified Capability Matrix</h2>
              <p className="text-xs text-[#b5c7d8]">Direct execution triggers for official script options.</p>
            </div>
            <span className="font-mono text-xs text-[#00e5ff] px-2 py-0.5 rounded bg-[#00e5ff]/10 border border-[#00e5ff]/25 font-semibold">
              JCVERSA/Ssh.jc
            </span>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3.5">
            <GlassCard
              variant="interactive"
              onClick={() => onNavigate('wizard')}
              className="p-3.5"
            >
              <div className="flex items-center justify-between">
                <span className="font-mono text-xs text-[#00e5ff] font-semibold">OPTION 1</span>
                <span className="text-[10px] text-[#10b981] font-mono px-2 py-0.5 bg-[#10b981]/15 border border-[#10b981]/30 rounded font-semibold uppercase">
                  RECOMMENDED
                </span>
              </div>
              <h4 className="text-sm font-semibold text-[#e6f1fc] mt-1.5 transition-colors">
                Full Automated Setup
              </h4>
              <p className="text-xs text-[#b5c7d8] mt-1">
                OpenSSH + tunnel client + Cloudflare tunnel + DNS route + background launch.
              </p>
            </GlassCard>

            <GlassCard
              variant="interactive"
              onClick={() => onNavigate('ssh')}
              className="p-3.5"
            >
              <div className="flex items-center justify-between">
                <span className="font-mono text-xs text-[#38bdf8] font-semibold">OPTION 2</span>
                <span className="text-[10px] text-[#7891a8] font-mono px-1.5 py-0.5 bg-[#071320] border border-[#1e334a] rounded">SSH ONLY</span>
              </div>
              <h4 className="text-sm font-semibold text-[#e6f1fc] mt-1.5 transition-colors">
                Install & Secure OpenSSH
              </h4>
              <p className="text-xs text-[#b5c7d8] mt-1">
                Install openssh-server, start daemon, create admin user with key dedup.
              </p>
            </GlassCard>

            <GlassCard
              variant="interactive"
              onClick={() => onNavigate('wizard')}
              className="p-3.5"
            >
              <div className="flex items-center justify-between">
                <span className="font-mono text-xs text-[#10b981] font-semibold">OPTION 3 & 4</span>
                <span className="text-[10px] text-[#7891a8] font-mono px-1.5 py-0.5 bg-[#071320] border border-[#1e334a] rounded">TUNNELS</span>
              </div>
              <h4 className="text-sm font-semibold text-[#e6f1fc] mt-1.5 transition-colors">
                Install Client & Route DNS
              </h4>
              <p className="text-xs text-[#b5c7d8] mt-1">
                Download cloudflared / fxTunnel, authenticate token, and set up subdomain DNS.
              </p>
            </GlassCard>

            <GlassCard
              variant="interactive"
              onClick={() => onNavigate('tunnels')}
              className="p-3.5"
            >
              <div className="flex items-center justify-between">
                <span className="font-mono text-xs text-[#f59e0b] font-semibold">OPTION 5</span>
                <span className="text-[10px] text-[#7891a8] font-mono px-1.5 py-0.5 bg-[#071320] border border-[#1e334a] rounded">DAEMON</span>
              </div>
              <h4 className="text-sm font-semibold text-[#e6f1fc] mt-1.5 transition-colors">
                Run Configured Tunnel
              </h4>
              <p className="text-xs text-[#b5c7d8] mt-1">
                Start existing tunnel in background nohup or systemd with port safeguard validation.
              </p>
            </GlassCard>
          </div>
        </GlassCard>

        {/* Right Col: Safeguards & Directives */}
        <GlassCard variant="default" className="flex flex-col justify-between space-y-4">
          <div>
            <div className="flex items-center justify-between border-b border-[#1e334a] pb-3">
              <h3 className="text-sm font-semibold text-[#e6f1fc]">Security Directives</h3>
              <span className="text-[11px] font-mono text-[#7891a8]">sshd -T audit</span>
            </div>

            <div className="mt-4 space-y-2.5 font-mono text-xs">
              <div className="p-2.5 bg-[#071320] rounded border border-[#1e334a] flex items-center justify-between">
                <span className="text-[#b5c7d8]">PermitRootLogin</span>
                <span
                  className={`font-semibold ${
                    ssh.permitRootLogin === 'no' || ssh.permitRootLogin === 'prohibit-password'
                      ? 'text-[#10b981]'
                      : 'text-[#ef4444]'
                  }`}
                >
                  {ssh.permitRootLogin}
                </span>
              </div>

              <div className="p-2.5 bg-[#071320] rounded border border-[#1e334a] flex items-center justify-between">
                <span className="text-[#b5c7d8]">PasswordAuthentication</span>
                <span
                  className={`font-semibold ${
                    ssh.passwordAuthentication === 'no' ? 'text-[#10b981]' : 'text-[#f59e0b]'
                  }`}
                >
                  {ssh.passwordAuthentication}
                </span>
              </div>

              <div className="p-2.5 bg-[#071320] rounded border border-[#1e334a] flex items-center justify-between">
                <span className="text-[#b5c7d8]">Configured Accounts</span>
                <span className="text-[#00e5ff] font-semibold truncate max-w-[120px]">
                  {ssh.configuredUsers.length > 0 ? ssh.configuredUsers.join(', ') : 'None'}
                </span>
              </div>

              <div className="p-2.5 bg-[#071320] rounded border border-[#ef4444]/35 flex items-center justify-between shadow-sm">
                <div className="flex items-center gap-1.5 text-[#ef4444]">
                  <PortGuardIcon size={13} />
                  <span>Console Port {status.protectedInfra.port} Ingress</span>
                </div>
                <span className="text-[#ef4444] font-semibold tracking-wider">LOCKED</span>
              </div>
            </div>
          </div>

          <div className="pt-3 border-t border-[#1e334a] text-[11px] text-[#7891a8] font-mono">
            Safety guarantee: public keys deduplicated, sshd_config automatically backed up.
          </div>
        </GlassCard>
      </div>
    </div>
  );
};
