import React, { useState } from 'react';
import { motion } from 'motion/react';
import {
  Smartphone,
  Laptop,
  Server,
  ArrowRight,
  Activity,
  CheckCircle2,
  Lock,
  Globe,
  Radio,
  Sparkles
} from 'lucide-react';
import { SystemStatusResponse, TunnelInstance } from '../types';
import {
  CyberKeyholeIcon,
  TunnelConduitIcon,
  BastionShieldIcon,
  PortGuardIcon,
  TelemetryRadarIcon,
  SftpExchangeIcon
} from './ui/Icons';
import { Badge } from './ui/Badge';

interface TopologyMapProps {
  status: SystemStatusResponse;
  onSelectNode: (nodeType: 'client' | 'ingress' | 'safeguard' | 'daemon', data?: any) => void;
}

export const TopologyMap: React.FC<TopologyMapProps> = ({ status, onSelectNode }) => {
  const { system, ssh, tunnels } = status;
  const activeTunnels = tunnels.filter((t) => t.isRunning);
  const primaryTunnel = tunnels[0];
  const isTunnelActive = activeTunnels.length > 0;

  const [hoveredTier, setHoveredTier] = useState<string | null>(null);

  const hostname = primaryTunnel?.hostname || 'ssh.example.com';
  const provider = system.activeProvider !== 'none' ? system.activeProvider : primaryTunnel?.provider || 'cloudflared';

  return (
    <div className="bg-[#0c1b2c]/85 backdrop-blur-2xl border border-[#1e334a] rounded p-5 relative overflow-hidden shadow-[0_12px_40px_rgba(0,0,0,0.4)]">
      {/* Topology Header */}
      <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-3 pb-4 border-b border-[#1e334a]">
        <div>
          <div className="flex items-center gap-2.5">
            <h2 className="text-sm font-semibold tracking-tight text-[#e6f1fc] flex items-center gap-2">
              <TelemetryRadarIcon size={18} className="text-[#00e5ff] animate-pulse" />
              <span>LIVE INGRESS TOPOLOGY & PORT ROUTING</span>
            </h2>
            <Badge variant={isTunnelActive ? 'active' : 'neutral'} pulse={isTunnelActive}>
              {isTunnelActive ? 'Ingress Synchronized' : 'Standby / Idle'}
            </Badge>
          </div>
          <p className="text-xs text-[#b5c7d8] mt-1">
            End-to-end traffic telemetry from remote clients through Cloudflare / fxTunnel to isolated local daemon.
          </p>
        </div>

        <div className="flex items-center gap-4 text-xs font-mono">
          <div className="flex items-center gap-1.5 text-[#b5c7d8]">
            <span className="w-2 h-2 rounded-full bg-[#10b981] animate-pulse" />
            <span>Port 22 Allowed</span>
          </div>
          <div className="flex items-center gap-1.5 text-[#ef4444]">
            <PortGuardIcon size={14} />
            <span className="font-semibold">Port 3000 Locked</span>
          </div>
        </div>
      </div>

      {/* Main Interactive Topology Pipeline Canvas */}
      <div className="py-6 relative">
        {/* Animated Connecting Data Conduits (Desktop View) */}
        <div className="hidden md:block absolute top-1/2 left-0 right-0 -translate-y-1/2 z-0 pointer-events-none px-12">
          <svg className="w-full h-12" preserveAspectRatio="none" viewBox="0 0 1000 48">
            <defs>
              <linearGradient id="conduitGrad" x1="0%" y1="0%" x2="100%" y2="0%">
                <stop offset="0%" stopColor="#00e5ff" stopOpacity="0.8" />
                <stop offset="50%" stopColor="#38bdf8" stopOpacity="0.8" />
                <stop offset="100%" stopColor="#10b981" stopOpacity="0.8" />
              </linearGradient>
            </defs>
            {/* Base Wireframe Line */}
            <line x1="40" y1="24" x2="960" y2="24" stroke="#1e334a" strokeWidth="2" strokeDasharray="4 4" />
            {/* Kinetic Active Packet Flow */}
            {isTunnelActive && (
              <line
                x1="40"
                y1="24"
                x2="960"
                y2="24"
                stroke="url(#conduitGrad)"
                strokeWidth="2.5"
                className="animate-flow-dash"
              />
            )}
          </svg>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-4 gap-4 relative z-10">
          {/* TIER 1: Remote Clients */}
          <motion.div
            whileHover={{ y: -3 }}
            onClick={() => onSelectNode('client', { hostname, user: ssh.configuredUsers[0] || 'root' })}
            onMouseEnter={() => setHoveredTier('client')}
            onMouseLeave={() => setHoveredTier(null)}
            className="bg-[#071320]/90 backdrop-blur-xl border border-[#1e334a] hover:border-[#00e5ff] rounded p-4 cursor-pointer transition-all flex flex-col justify-between group shadow-sm hover:shadow-[0_0_20px_rgba(0,229,255,0.15)]"
          >
            <div>
              <div className="flex items-center justify-between text-[#7891a8] text-[11px] font-mono mb-2">
                <span>TIER 1</span>
                <span>CLIENTS</span>
              </div>
              <div className="flex items-center gap-2 text-[#00e5ff] mb-2.5">
                <Smartphone className="w-4 h-4" />
                <Laptop className="w-4 h-4" />
                <span className="text-xs font-semibold text-[#e6f1fc]">Remote Endpoints</span>
              </div>
              <div className="space-y-1.5 text-xs font-mono text-[#b5c7d8]">
                <div className="flex items-center justify-between">
                  <span>Termux Android</span>
                  <span className="text-[#10b981] font-semibold text-[11px]">Ready</span>
                </div>
                <div className="flex items-center justify-between">
                  <span>Linux / macOS</span>
                  <span className="text-[#10b981] font-semibold text-[11px]">Ready</span>
                </div>
                <div className="flex items-center justify-between">
                  <span>SFTP GUI</span>
                  <span className="text-[#10b981] font-semibold text-[11px]">Ready</span>
                </div>
              </div>
            </div>
            <div className="mt-3 pt-2.5 border-t border-[#1e334a] text-[11px] font-mono text-[#00e5ff] flex items-center justify-between">
              <span>Inspect ProxyCommand</span>
              <ArrowRight className="w-3 h-3 group-hover:translate-x-1 transition-transform" />
            </div>
          </motion.div>

          {/* TIER 2: Ingress Cloud */}
          <motion.div
            whileHover={{ y: -3 }}
            onClick={() => onSelectNode('ingress', primaryTunnel || { provider })}
            onMouseEnter={() => setHoveredTier('ingress')}
            onMouseLeave={() => setHoveredTier(null)}
            className={`bg-[#071320]/90 backdrop-blur-xl border rounded p-4 cursor-pointer transition-all flex flex-col justify-between group shadow-sm ${
              isTunnelActive
                ? 'border-[#00e5ff]/60 shadow-[0_0_20px_rgba(0,229,255,0.15)]'
                : 'border-[#1e334a] hover:border-[#2f4d6d]'
            }`}
          >
            <div>
              <div className="flex items-center justify-between text-[#7891a8] text-[11px] font-mono mb-2">
                <span>TIER 2</span>
                <span className="uppercase text-[#38bdf8] font-semibold">{provider}</span>
              </div>
              <div className="flex items-center gap-2 text-[#00e5ff] mb-2.5">
                <Globe className="w-4 h-4" />
                <span className="text-xs font-semibold text-[#e6f1fc]">Tunnel Ingress</span>
              </div>
              <div className="space-y-1 text-xs font-mono text-[#b5c7d8]">
                <div className="truncate">
                  Host: <span className="text-[#00e5ff] font-semibold">{hostname}</span>
                </div>
                <div>Status: <span className={isTunnelActive ? 'text-[#10b981] font-semibold' : 'text-[#7891a8]'}>{isTunnelActive ? 'Active' : 'Offline'}</span></div>
                <div>Active PIDs: <span className="text-[#e6f1fc] font-semibold">{activeTunnels.length}</span></div>
              </div>
            </div>
            <div className="mt-3 pt-2.5 border-t border-[#1e334a] text-[11px] font-mono text-[#00e5ff] flex items-center justify-between">
              <span>Inspect Ingress Host</span>
              <ArrowRight className="w-3 h-3 group-hover:translate-x-1 transition-transform" />
            </div>
          </motion.div>

          {/* TIER 3: Safeguard Isolation Gate */}
          <motion.div
            whileHover={{ y: -3 }}
            onClick={() => onSelectNode('safeguard', status.protectedInfra)}
            onMouseEnter={() => setHoveredTier('safeguard')}
            onMouseLeave={() => setHoveredTier(null)}
            className="bg-[#071320]/90 backdrop-blur-xl border border-[#ef4444]/40 hover:border-[#ef4444] rounded p-4 cursor-pointer transition-all flex flex-col justify-between group shadow-sm hover:shadow-[0_0_20px_rgba(239,68,68,0.15)]"
          >
            <div>
              <div className="flex items-center justify-between text-[#7891a8] text-[11px] font-mono mb-2">
                <span>TIER 3</span>
                <span className="text-[#ef4444] font-semibold">GATEWAY</span>
              </div>
              <div className="flex items-center gap-2 text-[#ef4444] mb-2.5">
                <PortGuardIcon size={16} />
                <span className="text-xs font-semibold text-[#e6f1fc]">Safeguard Filter</span>
              </div>
              <div className="space-y-1.5 text-xs font-mono">
                <div className="flex items-center justify-between text-[#ef4444]">
                  <span>Port 3000:</span>
                  <span className="font-semibold text-[10px] px-1.5 py-0.2 bg-[#ef4444]/15 rounded border border-[#ef4444]/30">LOCKED</span>
                </div>
                <div className="flex items-center justify-between text-[#10b981]">
                  <span>Port 22 (SSH):</span>
                  <span className="font-semibold text-[10px] px-1.5 py-0.2 bg-[#10b981]/15 rounded border border-[#10b981]/30">ROUTED</span>
                </div>
                <div className="text-[10px] text-[#7891a8] truncate">
                  Dev Server: Protected
                </div>
              </div>
            </div>
            <div className="mt-3 pt-2.5 border-t border-[#1e334a] text-[11px] font-mono text-[#ef4444] flex items-center justify-between">
              <span>View Isolation Lock</span>
              <ArrowRight className="w-3 h-3 group-hover:translate-x-1 transition-transform" />
            </div>
          </motion.div>

          {/* TIER 4: OpenSSH Daemon */}
          <motion.div
            whileHover={{ y: -3 }}
            onClick={() => onSelectNode('daemon', ssh)}
            onMouseEnter={() => setHoveredTier('daemon')}
            onMouseLeave={() => setHoveredTier(null)}
            className="bg-[#071320]/90 backdrop-blur-xl border border-[#1e334a] hover:border-[#10b981] rounded p-4 cursor-pointer transition-all flex flex-col justify-between group shadow-sm hover:shadow-[0_0_20px_rgba(16,185,129,0.15)]"
          >
            <div>
              <div className="flex items-center justify-between text-[#7891a8] text-[11px] font-mono mb-2">
                <span>TIER 4</span>
                <span className="text-[#10b981] font-semibold">TARGET</span>
              </div>
              <div className="flex items-center gap-2 text-[#10b981] mb-2.5">
                <BastionShieldIcon size={16} />
                <span className="text-xs font-semibold text-[#e6f1fc]">OpenSSH Daemon</span>
              </div>
              <div className="space-y-1 text-xs font-mono text-[#b5c7d8]">
                <div>Port: <span className="text-[#00e5ff] font-semibold">{ssh.listeningPort}</span></div>
                <div>Status: <span className={ssh.isRunning ? 'text-[#10b981] font-semibold' : 'text-[#7891a8]'}>{ssh.isRunning ? 'Active' : 'Offline'}</span></div>
                <div>Users: <span className="text-[#e6f1fc] font-semibold">{ssh.configuredUsers.length}</span></div>
              </div>
            </div>
            <div className="mt-3 pt-2.5 border-t border-[#1e334a] text-[11px] font-mono text-[#10b981] flex items-center justify-between">
              <span>Inspect sshd State</span>
              <ArrowRight className="w-3 h-3 group-hover:translate-x-1 transition-transform" />
            </div>
          </motion.div>
        </div>
      </div>

      {/* Telemetry Footer Status Ticker */}
      <div className="mt-2 pt-3 border-t border-[#1e334a] flex flex-col sm:flex-row items-center justify-between gap-2 text-[11px] font-mono text-[#7891a8]">
        <div className="flex items-center gap-2">
          <span className="w-1.5 h-1.5 rounded-full bg-[#00e5ff] animate-ping" />
          <span>Real-time Ingress Synchronization</span>
          <span>·</span>
          <span>Carrier: {provider.toUpperCase()}</span>
        </div>
        <div className="flex items-center gap-3">
          <span>Active Tunnel PIDs: {activeTunnels.map(t => t.pid).filter(Boolean).join(', ') || 'None'}</span>
          <span>·</span>
          <span className="text-[#10b981]">Conduit Verified</span>
        </div>
      </div>
    </div>
  );
};
