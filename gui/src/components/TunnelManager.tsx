import React, { useState, useEffect } from 'react';
import {
  Globe,
  Copy,
  Check,
  Terminal,
  Server,
  AlertTriangle,
  RotateCw,
  Play,
  Square,
  Lock,
  ArrowRight
} from 'lucide-react';
import { SystemStatusResponse, TunnelInstance, JobState } from '../types';
import { stopTunnel, executeJob } from '../api';
import { Button } from './ui/Button';
import { Select } from './ui/Select';
import { GlassCard } from './ui/GlassCard';
import { TunnelConduitIcon, PortGuardIcon, SftpExchangeIcon } from './ui/Icons';

interface TunnelManagerProps {
  status: SystemStatusResponse;
  onJobStarted: (job: JobState) => void;
  onRefresh: () => void;
}

export const TunnelManager: React.FC<TunnelManagerProps> = ({
  status,
  onJobStarted,
  onRefresh
}) => {
  const { tunnels, system, ssh } = status;
  const [selectedTunnel, setSelectedTunnel] = useState<TunnelInstance | null>(tunnels[0] || null);

  // Re-sync the selection when fresh status arrives (e.g. fxTunnel has just
  // published its public endpoint) so commands appear without a page reload.
  useEffect(() => {
    setSelectedTunnel((prev) => {
      if (!prev) return tunnels[0] || null;
      return tunnels.find((t) => t.name === prev.name) || tunnels[0] || null;
    });
  }, [tunnels]);
  const [copiedCmd, setCopiedCmd] = useState<string | null>(null);
  const [isStopping, setIsStopping] = useState(false);

  // Quick run form for selected tunnel
  const [targetPort, setTargetPort] = useState('22');
  const [runMode, setRunMode] = useState<'background' | 'systemd'>(
    system.hasSystemd ? 'systemd' : 'background'
  );
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const handleCopy = (text: string, id: string) => {
    navigator.clipboard.writeText(text);
    setCopiedCmd(id);
    setTimeout(() => setCopiedCmd(null), 2000);
  };

  const handleStopTunnel = async (tunnelName: string) => {
    setIsStopping(true);
    setErrorMsg(null);
    try {
      const job = await stopTunnel(tunnelName);
      onJobStarted(job);
    } catch (err: any) {
      setErrorMsg(err.message);
    } finally {
      setIsStopping(false);
    }
  };

  const handleRunTunnel = async (tunnelName: string) => {
    setErrorMsg(null);
    const port = Number(targetPort);

    // Safeguard check: never tunnel the console's own port
    const protectedPort = status?.protectedInfra?.port ?? 3000;
    if (port === protectedPort) {
      setErrorMsg(`CRITICAL SAFEGUARD: Port ${protectedPort} is reserved for this Control Center. Choose port 22 or another non-conflicting port.`);
      return;
    }

    try {
      const job = await executeJob(
        'run_tunnel',
        {
          tunnelName,
          localPort: port,
          runMode,
          provider: selectedTunnel?.provider || system.activeProvider || 'cloudflared'
        }
      );
      onJobStarted(job);
    } catch (err: any) {
      setErrorMsg(err.message);
    }
  };

  const connectUser = selectedTunnel?.connectUser || ssh.configuredUsers[0] || 'root';
  const sshCmd = selectedTunnel?.connectCommand;
  const fxHost = selectedTunnel?.publicEndpoint
    ? selectedTunnel.publicEndpoint.slice(0, selectedTunnel.publicEndpoint.lastIndexOf(':'))
    : undefined;
  const fxPort = selectedTunnel?.publicEndpoint
    ? selectedTunnel.publicEndpoint.slice(selectedTunnel.publicEndpoint.lastIndexOf(':') + 1)
    : undefined;
  const clientHost = selectedTunnel?.hostname || selectedTunnel?.publicEndpoint || '—';
  const sftpCmd = !selectedTunnel
    ? undefined
    : selectedTunnel.provider === 'cloudflared' && selectedTunnel.hostname
      ? `sftp -o ProxyCommand="cloudflared access ssh --hostname ${selectedTunnel.hostname}" ${connectUser}@${selectedTunnel.hostname}`
      : fxHost && fxPort
        ? `sftp -P ${fxPort} ${connectUser}@${fxHost}`
        : undefined;
  const prereqCmd = selectedTunnel?.provider === 'fxtunnel' ? 'pkg install openssh' : 'pkg install openssh cloudflared';

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 pb-2 border-b border-[#1e334a]">
        <div>
          <h1 className="text-xl font-semibold tracking-tight text-[#e6f1fc] flex items-center gap-2.5">
            <TunnelConduitIcon size={22} className="text-[#00e5ff]" />
            <span>Tunnel Fleet & Ingress</span>
          </h1>
          <p className="text-xs text-[#b5c7d8] mt-0.5">
            Cloudflare Zero Trust tunnels and fxTunnel SaaS connections with port collision safeguards.
          </p>
        </div>

        <Button
          variant="secondary"
          size="sm"
          onClick={onRefresh}
          leftIcon={<RotateCw className="w-3.5 h-3.5 text-[#00e5ff]" />}
        >
          Sync Tunnels
        </Button>
      </div>

      {errorMsg && (
        <div className="p-3.5 bg-[#ef4444]/10 border border-[#ef4444]/30 rounded text-xs text-[#ffb4ab] flex items-center gap-2.5 backdrop-blur-md">
          <AlertTriangle className="w-4 h-4 text-[#ef4444] shrink-0" />
          <span>{errorMsg}</span>
        </div>
      )}

      {/* Configured Tunnels Grid */}
      <GlassCard variant="default" className="space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-semibold text-[#e6f1fc]">Registered Tunnels</h2>
          <span className="text-xs font-mono text-[#7891a8] px-2 py-0.5 rounded bg-[#071320] border border-[#1e334a]">
            {tunnels.length} configured
          </span>
        </div>

        {tunnels.length === 0 ? (
          <div className="p-8 text-center bg-[#071320] border border-[#1e334a] rounded space-y-2">
            <TunnelConduitIcon size={32} className="text-[#7891a8] mx-auto opacity-40" />
            <h4 className="text-sm font-medium text-[#e6f1fc]">No tunnels configured yet</h4>
            <p className="text-xs text-[#b5c7d8] max-w-md mx-auto">
              Run the installation wizard (Option 1 or Option 4) to register your Cloudflare domain or fxTunnel account.
            </p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-xs font-mono">
              <thead>
                <tr className="border-b border-[#1e334a] text-[#7891a8]">
                  <th className="py-2.5 px-3">TUNNEL NAME</th>
                  <th className="py-2.5 px-3">PROVIDER</th>
                  <th className="py-2.5 px-3">HOSTNAME / INGRESS</th>
                  <th className="py-2.5 px-3">STATUS</th>
                  <th className="py-2.5 px-3">PID</th>
                  <th className="py-2.5 px-3 text-right">ACTIONS</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-[#1e334a]/50">
                {tunnels.map((t) => {
                  const isSelected = selectedTunnel?.name === t.name;
                  return (
                    <tr
                      key={t.name}
                      onClick={() => setSelectedTunnel(t)}
                      className={`cursor-pointer transition-colors ${
                        isSelected ? 'bg-[#112234]/90' : 'hover:bg-[#071320]/70'
                      }`}
                    >
                      <td className="py-3 px-3 font-semibold text-[#e6f1fc]">{t.name}</td>
                      <td className="py-3 px-3 text-[#38bdf8] uppercase font-semibold">{t.provider}</td>
                      <td className="py-3 px-3 text-[#00e5ff] truncate max-w-xs">{t.hostname || t.publicEndpoint || 'Dynamic Port'}</td>
                      <td className="py-3 px-3">
                        <span
                          className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-[10px] font-semibold ${
                            t.isRunning
                              ? 'bg-[#10b981]/15 text-[#10b981] border border-[#10b981]/30'
                              : 'bg-[#1e334a] text-[#7891a8]'
                          }`}
                        >
                          <span
                            className={`w-1.5 h-1.5 rounded-full ${
                              t.isRunning ? 'bg-[#10b981] animate-pulse' : 'bg-[#7891a8]'
                            }`}
                          />
                          {t.isRunning ? 'ACTIVE' : 'STOPPED'}
                        </span>
                      </td>
                      <td className="py-3 px-3 text-[#b5c7d8]">{t.pid || '-'}</td>
                      <td className="py-3 px-3 text-right">
                        {t.isRunning ? (
                          <Button
                            variant="destructive"
                            size="sm"
                            disabled={isStopping}
                            onClick={(e) => {
                              e.stopPropagation();
                              handleStopTunnel(t.name);
                            }}
                          >
                            Stop
                          </Button>
                        ) : (
                          <Button
                            variant="primary"
                            size="sm"
                            onClick={(e) => {
                              e.stopPropagation();
                              handleRunTunnel(t.name);
                            }}
                          >
                            Launch
                          </Button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </GlassCard>

      {/* Selected Tunnel Details & Client Connection Command Generator */}
      {selectedTunnel && (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* Left: Client Connection Instructions */}
          <GlassCard variant="default" className="space-y-4">
            <div className="flex items-center justify-between border-b border-[#1e334a] pb-3">
              <div>
                <h3 className="text-sm font-semibold text-[#e6f1fc]">Client Connection Generator</h3>
                <p className="text-xs text-[#b5c7d8]">Direct commands generated for remote terminals.</p>
              </div>
              <span className="text-xs font-mono text-[#00e5ff] px-2 py-0.5 rounded bg-[#00e5ff]/10 border border-[#00e5ff]/25 font-semibold">
                {selectedTunnel.name}
              </span>
            </div>

            {/* Step 1: Client prerequisites */}
            <div className="space-y-2">
              <span className="text-xs font-medium text-[#b5c7d8] block">1. Client Prerequisite Package:</span>
              <div className="p-3 bg-[#071320] border border-[#1e334a] rounded font-mono text-xs text-[#e6f1fc] flex items-center justify-between">
                <code>{prereqCmd}</code>
                <button
                  onClick={() => handleCopy(prereqCmd, 'req-termux')}
                  className="p-1 hover:bg-[#112234] rounded text-[#7891a8] hover:text-[#00e5ff] cursor-pointer"
                  title="Copy command"
                >
                  {copiedCmd === 'req-termux' ? <Check className="w-3.5 h-3.5 text-[#10b981]" /> : <Copy className="w-3.5 h-3.5" />}
                </button>
              </div>
            </div>

            {/* Step 2: SSH Command */}
            <div className="space-y-2">
              <span className="text-xs font-medium text-[#b5c7d8] block">2. Remote SSH Terminal Command:</span>
              {sshCmd ? (
                <div className="p-3 bg-[#071320] border border-[#1e334a] rounded font-mono text-xs text-[#00e5ff] flex items-center justify-between">
                  <code className="break-all">{sshCmd}</code>
                  <button
                    onClick={() => handleCopy(sshCmd, 'ssh-cmd')}
                    className="ml-2 p-1 hover:bg-[#112234] rounded text-[#7891a8] hover:text-[#00e5ff] shrink-0 cursor-pointer"
                    title="Copy command"
                  >
                    {copiedCmd === 'ssh-cmd' ? <Check className="w-3.5 h-3.5 text-[#10b981]" /> : <Copy className="w-3.5 h-3.5" />}
                  </button>
                </div>
              ) : (
                <div className="p-3 bg-[#071320] border border-[#1e334a] rounded text-xs text-[#b5c7d8]">
                  {selectedTunnel.provider === 'fxtunnel'
                    ? selectedTunnel.isRunning
                      ? 'fxTunnel is starting: the assigned public address and the exact command will appear here automatically.'
                      : 'Start the tunnel: as soon as fxTunnel assigns the public address, the exact connect command appears here.'
                    : 'No hostname yet: run "Create / Configure Tunnel" (wizard option 4) so the DNS route exists.'}
                </div>
              )}
            </div>

            {/* Step 3: SFTP File Transfer */}
            <div className="space-y-2">
              <span className="text-xs font-medium text-[#b5c7d8] block">3. SFTP File Transfer Command:</span>
              {sftpCmd ? (
                <div className="p-3 bg-[#071320] border border-[#1e334a] rounded font-mono text-xs text-[#e6f1fc] flex items-center justify-between">
                  <code className="break-all">{sftpCmd}</code>
                  <button
                    onClick={() => handleCopy(sftpCmd, 'sftp-cmd')}
                    className="ml-2 p-1 hover:bg-[#112234] rounded text-[#7891a8] hover:text-[#00e5ff] shrink-0 cursor-pointer"
                    title="Copy command"
                  >
                    {copiedCmd === 'sftp-cmd' ? <Check className="w-3.5 h-3.5 text-[#10b981]" /> : <Copy className="w-3.5 h-3.5" />}
                  </button>
                </div>
              ) : (
                <div className="p-3 bg-[#071320] border border-[#1e334a] rounded text-xs text-[#b5c7d8]">
                  Available as soon as the SSH command above is known.
                </div>
              )}
              <p className="text-[11px] text-[#7891a8] leading-relaxed">
                For FileZilla or WinSCP: choose protocol SFTP, host {clientHost}, and configure the ProxyCommand in advanced settings.
              </p>
            </div>
          </GlassCard>

          {/* Right: Launch Controls & Port Guard */}
          <GlassCard variant="default" className="space-y-4">
            <h3 className="text-sm font-semibold text-[#e6f1fc]">Tunnel Launch Parameters</h3>
            <p className="text-xs text-[#b5c7d8]">Launch daemon in background or register as systemd service.</p>

            <div className="space-y-4">
              <div>
                <label className="text-xs font-medium text-[#e6f1fc] block mb-1">Local Expose Port</label>
                <input
                  type="number"
                  min="1"
                  max="65535"
                  value={targetPort}
                  onChange={(e) => setTargetPort(e.target.value)}
                  className="w-full px-3.5 py-2.5 bg-[#071320]/80 border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none backdrop-blur-md transition-all focus:ring-1 focus:ring-[#00e5ff]"
                />
                {Number(targetPort) === 3000 && (
                  <p className="text-[11px] text-[#ef4444] font-mono mt-1.5 flex items-center gap-1.5">
                    <PortGuardIcon size={12} />
                    <span>Port 3000 is locked: Dev container server uses this port.</span>
                  </p>
                )}
              </div>

              {/* Custom Popover Select for Execution Mode */}
              <Select
                label="Execution Mode"
                value={runMode}
                onChange={(val) => setRunMode(val as any)}
                options={[
                  {
                    value: 'background',
                    label: 'nohup Background Process',
                    description: 'Runs in background session. Logs stream to /tmp.',
                    badge: 'Universal'
                  },
                  {
                    value: 'systemd',
                    label: 'systemd System Service',
                    description: 'Managed by systemctl. Automatically restarts on boot.',
                    badge: system.hasSystemd ? 'Persistent' : 'Disabled (No systemd)'
                  }
                ]}
              />

              <div className="p-3 bg-[#071320] rounded border border-[#1e334a] text-xs font-mono space-y-1.5">
                <div className="text-[#7891a8]">Active Process ID:</div>
                <div className="text-[#e6f1fc] font-semibold">{selectedTunnel.pid || 'Not running'}</div>
                {selectedTunnel.logFile && (
                  <div className="text-[#7891a8] truncate">
                    Log Path: <span className="text-[#00e5ff]">{selectedTunnel.logFile}</span>
                  </div>
                )}
              </div>

              <Button
                variant={selectedTunnel.isRunning ? 'secondary' : 'primary'}
                size="md"
                onClick={() => handleRunTunnel(selectedTunnel.name)}
                disabled={selectedTunnel.isRunning}
                className="w-full mt-2"
                leftIcon={<Play className="w-3.5 h-3.5 fill-current" />}
              >
                {selectedTunnel.isRunning ? 'Tunnel Running' : 'Start Tunnel Service'}
              </Button>
            </div>
          </GlassCard>
        </div>
      )}
    </div>
  );
};
