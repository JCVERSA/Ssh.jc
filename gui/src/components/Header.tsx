import React from 'react';
import { motion } from 'motion/react';
import {
  RotateCw,
  ChevronRight,
  Activity,
  XOctagon
} from 'lucide-react';
import { SystemStatusResponse, JobState } from '../types';
import { Button } from './ui/Button';
import { Badge } from './ui/Badge';
import { PortGuardIcon } from './ui/Icons';

interface HeaderProps {
  currentTab: string;
  onRefresh: () => void;
  isRefreshing: boolean;
  activeJob: JobState | null;
  onCancelJob: (id: string) => void;
  onOpenSafeguard: () => void;
}

export const Header: React.FC<HeaderProps> = ({
  currentTab,
  onRefresh,
  isRefreshing,
  activeJob,
  onCancelJob,
  onOpenSafeguard
}) => {
  const tabTitles: Record<string, string> = {
    dashboard: 'Live Ingress Topology',
    wizard: 'Installation Studio',
    ssh: 'OpenSSH Bastion',
    tunnels: 'Tunnel Fleet Ingress',
    logs: 'Flight Recorder Logs'
  };

  const isJobActive =
    activeJob && (activeJob.status === 'running' || activeJob.status === 'preparing');

  return (
    <header className="sticky top-0 z-20 bg-[#051424]/85 backdrop-blur-xl border-b border-[#1e334a] px-4 sm:px-6 h-16 flex items-center justify-between gap-4 shadow-sm">
      {/* Breadcrumb Navigation */}
      <div className="flex items-center gap-2 text-xs font-mono">
        <span className="text-[#7891a8] hover:text-[#e6f1fc] transition-colors cursor-pointer font-medium">
          SSH.JC
        </span>
        <ChevronRight className="w-3 h-3 text-[#2f4d6d]" />
        <span className="text-[#00e5ff] font-semibold tracking-tight">
          {tabTitles[currentTab] || 'Workspace'}
        </span>
      </div>

      {/* Active Job Alert Pill */}
      {isJobActive && (
        <motion.div
          initial={{ opacity: 0, y: -5 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -5 }}
          className="hidden md:flex items-center gap-3 px-3 py-1.5 bg-[#112234] border border-[#00e5ff]/50 rounded text-xs font-mono shadow-[0_0_15px_rgba(0,229,255,0.2)]"
        >
          <Activity className="w-3.5 h-3.5 text-[#00e5ff] animate-spin" />
          <span className="text-[#e6f1fc] font-semibold truncate max-w-xs">
            {activeJob.title}
          </span>
          <button
            onClick={() => onCancelJob(activeJob.id)}
            className="text-[11px] text-[#ef4444] hover:underline flex items-center gap-1 font-mono cursor-pointer"
          >
            <XOctagon className="w-3 h-3" />
            <span>Abort</span>
          </button>
        </motion.div>
      )}

      {/* Action Controls */}
      <div className="flex items-center gap-2.5">
        {/* Port 3000 Hardware Lock Badge Button */}
        <button
          onClick={onOpenSafeguard}
          title="Click to view Port 3000 container isolation specs"
          className="focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#ef4444] rounded cursor-pointer transition-transform hover:scale-105"
        >
          <Badge variant="locked" pulse={true}>
            <span className="flex items-center gap-1.5">
              <PortGuardIcon size={12} />
              <span>Port 3000 Locked</span>
            </span>
          </Badge>
        </button>

        {/* Sync State Button */}
        <Button
          variant="secondary"
          size="sm"
          onClick={onRefresh}
          disabled={isRefreshing}
          isLoading={isRefreshing}
          title="Sync Host Telemetry"
        >
          <RotateCw className="w-3.5 h-3.5" />
        </Button>
      </div>
    </header>
  );
};
