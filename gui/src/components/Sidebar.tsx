import React from 'react';
import { motion } from 'motion/react';
import {
  ChevronLeft,
  ChevronRight,
  Server,
  Activity,
  Cpu,
  Lock,
  FileCode
} from 'lucide-react';
import { SystemStatusResponse } from '../types';
import { Logo } from './ui/Logo';
import { Badge } from './ui/Badge';
import {
  CyberKeyholeIcon,
  TunnelConduitIcon,
  BastionShieldIcon,
  PortGuardIcon,
  TelemetryRadarIcon
} from './ui/Icons';

interface SidebarProps {
  currentTab: string;
  onSelectTab: (tab: string) => void;
  isCollapsed: boolean;
  onToggleCollapse: () => void;
  status: SystemStatusResponse | null;
}

export const Sidebar: React.FC<SidebarProps> = ({
  currentTab,
  onSelectTab,
  isCollapsed,
  onToggleCollapse,
  status
}) => {
  const navItems = [
    {
      id: 'dashboard',
      label: 'Live Topology',
      subtitle: 'Traffic & Conduit',
      icon: TelemetryRadarIcon,
      badge: status?.tunnels.filter((t) => t.isRunning).length || 0,
      badgeColor: 'text-[#00e5ff] bg-[#00e5ff]/10 border-[#00e5ff]/30'
    },
    {
      id: 'wizard',
      label: 'Install Wizard',
      subtitle: '6 Official Modes',
      icon: CyberKeyholeIcon,
      badge: 'v1.0',
      badgeColor: 'text-[#b5c7d8] bg-[#112234] border-[#1e334a]'
    },
    {
      id: 'ssh',
      label: 'SSH Bastion',
      subtitle: 'Keys & Directives',
      icon: BastionShieldIcon,
      badge: status?.ssh.isRunning ? 'Active' : 'Offline',
      badgeColor: status?.ssh.isRunning
        ? 'text-[#10b981] bg-[#10b981]/15 border-[#10b981]/30'
        : 'text-[#7891a8] bg-[#112234] border-[#1e334a]'
    },
    {
      id: 'tunnels',
      label: 'Tunnel Fleet',
      subtitle: 'Endpoints & Ingress',
      icon: TunnelConduitIcon,
      badge: status?.tunnels.length || 0,
      badgeColor: 'text-[#38bdf8] bg-[#112234] border-[#1e334a]'
    },
    {
      id: 'logs',
      label: 'Flight Recorder',
      subtitle: 'Real-time Telemetry',
      icon: FileCode,
      badge: 'Live',
      badgeColor: 'text-[#10b981] bg-[#10b981]/10 border-[#10b981]/30'
    }
  ];

  return (
    <motion.aside
      animate={{ width: isCollapsed ? 70 : 264 }}
      transition={{ type: 'spring', stiffness: 350, damping: 32 }}
      className="bg-[#051424]/90 backdrop-blur-2xl border-r border-[#1e334a] flex flex-col justify-between shrink-0 h-screen sticky top-0 z-30 select-none overflow-hidden shadow-xl"
    >
      {/* Top Header / Cybernetic Keyhole Wordmark */}
      <div className="p-3.5 border-b border-[#1e334a] bg-[#030d18]/50">
        {isCollapsed ? (
          <div className="flex justify-center">
            <Logo variant="icon" size="sm" pulse={true} />
          </div>
        ) : (
          <Logo variant="horizontal" size="md" pulse={true} />
        )}
      </div>

      {/* Nav Items List */}
      <nav className="flex-1 px-2.5 py-4 space-y-1.5 overflow-y-auto">
        {navItems.map((item) => {
          const Icon = item.icon;
          const isActive = currentTab === item.id;

          return (
            <button
              key={item.id}
              onClick={() => onSelectTab(item.id)}
              title={isCollapsed ? item.label : undefined}
              className={`w-full group relative flex items-center gap-3 px-3 py-2.5 rounded text-left transition-all backdrop-blur-md ${
                isActive
                  ? 'bg-[#0c1b2c] text-[#00e5ff] border border-[#00e5ff]/45 shadow-[0_0_15px_rgba(0,229,255,0.12)]'
                  : 'text-[#b5c7d8] hover:text-[#e6f1fc] hover:bg-[#0c1b2c]/60 border border-transparent'
              }`}
            >
              {/* Left active marker indicator with animated glow */}
              {isActive && (
                <motion.div
                  layoutId="activeTabIndicator"
                  className="absolute left-0 top-1.5 bottom-1.5 w-1 bg-[#00e5ff] rounded-r shadow-[0_0_8px_#00e5ff]"
                />
              )}

              <Icon
                size={18}
                className={`shrink-0 transition-transform group-hover:scale-110 ${
                  isActive ? 'text-[#00e5ff]' : 'text-[#7891a8] group-hover:text-[#e6f1fc]'
                }`}
              />

              {!isCollapsed && (
                <div className="flex-1 flex items-center justify-between min-w-0 overflow-hidden">
                  <div className="truncate">
                    <div className="text-xs font-medium leading-none truncate text-[#e6f1fc]">
                      {item.label}
                    </div>
                    <div className="text-[10px] font-mono text-[#7891a8] mt-0.5 truncate">
                      {item.subtitle}
                    </div>
                  </div>
                  {item.badge !== undefined && (
                    <span
                      className={`text-[10px] font-mono px-1.5 py-0.5 rounded border ml-2 shrink-0 ${item.badgeColor}`}
                    >
                      {item.badge}
                    </span>
                  )}
                </div>
              )}
            </button>
          );
        })}
      </nav>

      {/* Persistent Telemetry Badges & Collapse Toggle */}
      <div className="p-3 border-t border-[#1e334a] space-y-2 bg-[#030d18]/70 backdrop-blur-md">
        {!isCollapsed && status && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            className="space-y-1.5 font-mono text-[11px]"
          >
            {/* Port 3000 Shield */}
            <div className="p-2 bg-[#0c1b2c]/90 border border-[#ef4444]/35 rounded flex items-center justify-between shadow-sm">
              <div className="flex items-center gap-1.5 text-[#ef4444]">
                <PortGuardIcon size={14} />
                <span>Port 3000</span>
              </div>
              <span className="text-[10px] text-[#ef4444] font-semibold tracking-wider">
                LOCKED
              </span>
            </div>

            {/* SSH Service Status */}
            <div className="p-2 bg-[#0c1b2c]/90 border border-[#1e334a] rounded flex items-center justify-between shadow-sm">
              <div className="flex items-center gap-1.5 text-[#b5c7d8]">
                <Server className="w-3.5 h-3.5 text-[#00e5ff]" />
                <span>SSH:22</span>
              </div>
              <span
                className={
                  status.ssh.isRunning
                    ? 'text-[#10b981] font-semibold'
                    : 'text-[#7891a8]'
                }
              >
                {status.ssh.isRunning ? 'RUNNING' : 'STOPPED'}
              </span>
            </div>

            {/* Architecture */}
            <div className="p-1.5 bg-[#071320] rounded border border-[#1e334a] text-[10px] text-[#7891a8] flex items-center justify-between">
              <span>{status.system.architecture}</span>
              <span>Debian 12</span>
            </div>
          </motion.div>
        )}

        {/* Collapse Button */}
        <button
          onClick={onToggleCollapse}
          className="w-full flex items-center justify-center p-2 rounded hover:bg-[#112234] text-[#7891a8] hover:text-[#e6f1fc] border border-[#1e334a] transition-all cursor-pointer"
          title={isCollapsed ? 'Expand Sidebar' : 'Collapse Sidebar'}
        >
          {isCollapsed ? (
            <ChevronRight className="w-4 h-4" />
          ) : (
            <ChevronLeft className="w-4 h-4" />
          )}
        </button>
      </div>
    </motion.aside>
  );
};
