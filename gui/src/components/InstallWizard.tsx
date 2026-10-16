import React, { useState } from 'react';
import {
  Play,
  CheckCircle2,
  AlertTriangle,
  Server,
  Lock,
  ChevronRight,
  ShieldCheck,
  RotateCw,
  XOctagon,
  Copy,
  Check,
  Terminal,
  FileCode
} from 'lucide-react';
import { SystemStatusResponse, JobType, JobState } from '../types';
import { executeJob, cancelJob } from '../api';
import { Button } from './ui/Button';
import { Select } from './ui/Select';
import { Checkbox } from './ui/Checkbox';
import { GlassCard } from './ui/GlassCard';
import { Badge } from './ui/Badge';
import {
  CyberKeyholeIcon,
  TunnelConduitIcon,
  BastionShieldIcon,
  PortGuardIcon
} from './ui/Icons';

interface InstallWizardProps {
  status: SystemStatusResponse;
  activeJob: JobState | null;
  onJobStarted: (job: JobState) => void;
  onJobCancelled: (jobId: string) => void;
}

export const InstallWizard: React.FC<InstallWizardProps> = ({
  status,
  activeJob,
  onJobStarted,
  onJobCancelled
}) => {
  const [selectedMode, setSelectedMode] = useState<JobType>('full_setup');
  const [step, setStep] = useState<'select' | 'configure' | 'review' | 'running'>('select');

  // Form State
  const [provider, setProvider] = useState<'cloudflared' | 'fxtunnel'>('cloudflared');
  const [tunnelName, setTunnelName] = useState('ssh-sandbox');
  const [domain, setDomain] = useState('jcversanb.dpdns.org');
  const [subdomain, setSubdomain] = useState('ssh');
  const [fxToken, setFxToken] = useState('');
  const [localPort, setLocalPort] = useState('22');
  const [runMode, setRunMode] = useState<'background' | 'systemd'>(status.system.hasSystemd ? 'systemd' : 'background');
  const [createAdmin, setCreateAdmin] = useState(true);
  const [username, setUsername] = useState('admin');
  const [pubkey, setPubkey] = useState('');
  const [disablePasswordAuth, setDisablePasswordAuth] = useState(false);

  const [validationError, setValidationError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [copiedCmd, setCopiedCmd] = useState(false);

  // If there's an active job running, lock to running view
  const isJobRunning = activeJob && (activeJob.status === 'running' || activeJob.status === 'preparing');

  const handleNextToReview = () => {
    setValidationError(null);

    // Safeguard check for port 3000
    if (Number(localPort) === 3000) {
      setValidationError('CRITICAL SAFEGUARD: Port 3000 is reserved for AI Studio and the existing tunnel. Please choose port 22 or another non-conflicting port.');
      return;
    }

    if (selectedMode === 'configure_tunnel' || selectedMode === 'full_setup') {
      if (provider === 'fxtunnel' && (!fxToken || !fxToken.startsWith('sk_'))) {
        setValidationError('fxTunnel requires an API token starting with "sk_".');
        return;
      }
      if (provider === 'cloudflared' && !domain) {
        setValidationError('A domain added to Cloudflare is required to route DNS.');
        return;
      }
    }

    if (pubkey && !pubkey.trim().startsWith('ssh-')) {
      setValidationError('Public key must be in OpenSSH format (e.g. ssh-ed25519 AAAAC... or ssh-rsa AAAAB...).');
      return;
    }

    setStep('review');
  };

  const handleStartExecution = async () => {
    setIsSubmitting(true);
    setValidationError(null);

    const parameters: Record<string, any> = {
      provider,
      tunnelName,
      domain,
      subdomain,
      fxToken,
      localPort: Number(localPort),
      runMode,
      username: createAdmin ? username : undefined,
      pubkey: createAdmin && pubkey.trim() ? pubkey.trim() : undefined,
      disablePasswordAuth: createAdmin && disablePasswordAuth
    };

    try {
      const job = await executeJob(selectedMode, parameters);
      onJobStarted(job);
      setStep('running');
    } catch (err: any) {
      setValidationError(err.message);
    } finally {
      setIsSubmitting(false);
    }
  };

  const fullHostname = subdomain ? `${subdomain}.${domain}` : domain;
  const connectionUser = createAdmin && username ? username : 'root';
  const connectionCmd =
    provider === 'cloudflared'
      ? `ssh -o ProxyCommand="cloudflared access ssh --hostname ${fullHostname}" ${connectionUser}@${fullHostname}`
      : `ssh -p <port> ${connectionUser}@<fxtunnel-host>`;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 pb-2 border-b border-[#1e334a]">
        <div>
          <h1 className="text-xl font-semibold tracking-tight text-[#e6f1fc] flex items-center gap-2.5">
            <CyberKeyholeIcon size={22} className="text-[#00e5ff]" />
            <span>Guided Installation Wizard</span>
          </h1>
          <p className="text-xs text-[#b5c7d8] mt-0.5">
            Strictly executes verified functions from the official Install.sh installer with environment safeguards.
          </p>
        </div>

        {/* Wizard progress tabs */}
        <div className="flex items-center gap-1.5 text-xs font-mono bg-[#071320] p-1 rounded border border-[#1e334a]">
          <span className={`px-2.5 py-1 rounded ${step === 'select' ? 'bg-[#112234] text-[#00e5ff] font-semibold border border-[#00e5ff]/30' : 'text-[#7891a8]'}`}>
            1. Select
          </span>
          <ChevronRight className="w-3 h-3 text-[#2f4d6d]" />
          <span className={`px-2.5 py-1 rounded ${step === 'configure' ? 'bg-[#112234] text-[#00e5ff] font-semibold border border-[#00e5ff]/30' : 'text-[#7891a8]'}`}>
            2. Configure
          </span>
          <ChevronRight className="w-3 h-3 text-[#2f4d6d]" />
          <span className={`px-2.5 py-1 rounded ${step === 'review' ? 'bg-[#112234] text-[#00e5ff] font-semibold border border-[#00e5ff]/30' : 'text-[#7891a8]'}`}>
            3. Review
          </span>
          <ChevronRight className="w-3 h-3 text-[#2f4d6d]" />
          <span className={`px-2.5 py-1 rounded ${step === 'running' || isJobRunning ? 'bg-[#112234] text-[#10b981] font-semibold border border-[#10b981]/30' : 'text-[#7891a8]'}`}>
            4. Execution
          </span>
        </div>
      </div>

      {validationError && (
        <div className="p-3.5 bg-[#ef4444]/10 border border-[#ef4444]/30 rounded text-xs text-[#ffb4ab] flex items-start gap-2.5 backdrop-blur-md">
          <AlertTriangle className="w-4 h-4 text-[#ef4444] shrink-0 mt-0.5" />
          <div className="space-y-1">
            <span className="font-semibold block">Validation Alert</span>
            <span>{validationError}</span>
          </div>
        </div>
      )}

      {/* STEP 1: Select Operation */}
      {step === 'select' && (
        <div className="space-y-4">
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {/* Option 1: Full Setup */}
            <GlassCard
              variant={selectedMode === 'full_setup' ? 'accent' : 'interactive'}
              onClick={() => setSelectedMode('full_setup')}
            >
              <div className="flex items-center justify-between">
                <span className="font-mono text-xs text-[#00e5ff] font-semibold">OPTION 1</span>
                <span className="text-[10px] font-mono text-[#10b981] px-2 py-0.5 bg-[#10b981]/15 border border-[#10b981]/30 rounded font-semibold uppercase">
                  RECOMMENDED
                </span>
              </div>
              <h3 className="text-sm font-semibold text-[#e6f1fc] mt-2">Full Automated Setup</h3>
              <p className="text-xs text-[#b5c7d8] mt-1 leading-relaxed">
                Complete workflow: installs OpenSSH, provisions tunnel client, configures DNS route, and starts service.
              </p>
            </GlassCard>

            {/* Option 2: OpenSSH Only */}
            <GlassCard
              variant={selectedMode === 'install_openssh' ? 'accent' : 'interactive'}
              onClick={() => setSelectedMode('install_openssh')}
            >
              <span className="font-mono text-xs text-[#38bdf8] font-semibold">OPTION 2</span>
              <h3 className="text-sm font-semibold text-[#e6f1fc] mt-2">OpenSSH Server Only</h3>
              <p className="text-xs text-[#b5c7d8] mt-1 leading-relaxed">
                Installs openssh-server, starts sshd daemon, creates admin user with authorized_keys, and enables SFTP.
              </p>
            </GlassCard>

            {/* Option 3: Tunnel Client Only */}
            <GlassCard
              variant={selectedMode === 'install_tunnel_client' ? 'accent' : 'interactive'}
              onClick={() => setSelectedMode('install_tunnel_client')}
            >
              <span className="font-mono text-xs text-[#10b981] font-semibold">OPTION 3</span>
              <h3 className="text-sm font-semibold text-[#e6f1fc] mt-2">Install Tunnel Client Only</h3>
              <p className="text-xs text-[#b5c7d8] mt-1 leading-relaxed">
                Downloads and installs official package: cloudflared (.deb with sha256 check) or fxTunnel binary.
              </p>
            </GlassCard>

            {/* Option 4: Configure Tunnel */}
            <GlassCard
              variant={selectedMode === 'configure_tunnel' ? 'accent' : 'interactive'}
              onClick={() => setSelectedMode('configure_tunnel')}
            >
              <span className="font-mono text-xs text-[#f59e0b] font-semibold">OPTION 4</span>
              <h3 className="text-sm font-semibold text-[#e6f1fc] mt-2">Create / Configure Tunnel</h3>
              <p className="text-xs text-[#b5c7d8] mt-1 leading-relaxed">
                Pairs existing client with Cloudflare domain DNS or saves fxTunnel authentication token.
              </p>
            </GlassCard>

            {/* Option 5: Run Tunnel */}
            <GlassCard
              variant={selectedMode === 'run_tunnel' ? 'accent' : 'interactive'}
              onClick={() => setSelectedMode('run_tunnel')}
            >
              <span className="font-mono text-xs text-[#00e5ff] font-semibold">OPTION 5</span>
              <h3 className="text-sm font-semibold text-[#e6f1fc] mt-2">Run Configured Tunnel</h3>
              <p className="text-xs text-[#b5c7d8] mt-1 leading-relaxed">
                Launches configured tunnel in background (nohup) or systemd service, guarding port 3000.
              </p>
            </GlassCard>
          </div>

          <div className="flex justify-end pt-4 border-t border-[#1e334a]">
            <Button
              variant="primary"
              size="md"
              onClick={() => setStep('configure')}
              rightIcon={<ChevronRight className="w-3.5 h-3.5" />}
            >
              Continue to Parameters
            </Button>
          </div>
        </div>
      )}

      {/* STEP 2: Configure Parameters */}
      {step === 'configure' && (
        <GlassCard variant="default" className="space-y-5">
          <div className="border-b border-[#1e334a] pb-3">
            <h3 className="text-sm font-semibold text-[#e6f1fc]">Operation Parameters</h3>
            <p className="text-xs text-[#b5c7d8]">Configure required parameters for the chosen operation.</p>
          </div>

          {/* Provider Selection with Custom Popover */}
          {(selectedMode === 'full_setup' || selectedMode === 'install_tunnel_client' || selectedMode === 'configure_tunnel') && (
            <Select
              label="Tunnel Provider"
              value={provider}
              onChange={(val) => setProvider(val as any)}
              options={[
                {
                  value: 'cloudflared',
                  label: 'Cloudflare Tunnel (cloudflared)',
                  description: 'Custom domain DNS routing via Cloudflare Zero Trust',
                  badge: 'Standard'
                },
                {
                  value: 'fxtunnel',
                  label: 'fxTunnel (fxtun.dev)',
                  description: 'SaaS TCP tunnel with token authentication',
                  badge: 'SaaS'
                }
              ]}
            />
          )}

          {/* Cloudflare Domain Routing */}
          {provider === 'cloudflared' && (selectedMode === 'full_setup' || selectedMode === 'configure_tunnel') && (
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label className="text-xs font-medium text-[#e6f1fc] block mb-1">Tunnel Identifier</label>
                <input
                  type="text"
                  value={tunnelName}
                  onChange={(e) => setTunnelName(e.target.value)}
                  className="w-full px-3.5 py-2.5 bg-[#071320]/80 border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none backdrop-blur-md transition-all focus:ring-1 focus:ring-[#00e5ff]"
                  placeholder="ssh-sandbox"
                />
              </div>

              <div>
                <label className="text-xs font-medium text-[#e6f1fc] block mb-1">Subdomain</label>
                <input
                  type="text"
                  value={subdomain}
                  onChange={(e) => setSubdomain(e.target.value)}
                  className="w-full px-3.5 py-2.5 bg-[#071320]/80 border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none backdrop-blur-md transition-all focus:ring-1 focus:ring-[#00e5ff]"
                  placeholder="ssh"
                />
              </div>

              <div className="sm:col-span-2">
                <label className="text-xs font-medium text-[#e6f1fc] block mb-1">Root Domain (on Cloudflare)</label>
                <input
                  type="text"
                  value={domain}
                  onChange={(e) => setDomain(e.target.value)}
                  className="w-full px-3.5 py-2.5 bg-[#071320]/80 border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none backdrop-blur-md transition-all focus:ring-1 focus:ring-[#00e5ff]"
                  placeholder="jcversanb.dpdns.org"
                />
                <p className="text-[11px] font-mono text-[#7891a8] mt-1">
                  Resulting Public Endpoint: <span className="text-[#00e5ff]">{fullHostname}</span>
                </p>
              </div>
            </div>
          )}

          {/* fxTunnel Token */}
          {provider === 'fxtunnel' && (selectedMode === 'full_setup' || selectedMode === 'configure_tunnel') && (
            <div>
              <label className="text-xs font-medium text-[#e6f1fc] block mb-1">fxTunnel Account Token</label>
              <input
                type="password"
                value={fxToken}
                onChange={(e) => setFxToken(e.target.value)}
                className="w-full px-3.5 py-2.5 bg-[#071320]/80 border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none backdrop-blur-md transition-all focus:ring-1 focus:ring-[#00e5ff]"
                placeholder="sk_live_..."
              />
              <p className="text-[11px] text-[#7891a8] mt-1">Generated from your fxtun.dev dashboard. Masked on storage.</p>
            </div>
          )}

          {/* Local Port Safeguard Input */}
          {(selectedMode === 'full_setup' || selectedMode === 'run_tunnel') && (
            <div className="p-3.5 bg-[#071320] border border-[#1e334a] rounded space-y-2">
              <div className="flex items-center justify-between">
                <label className="text-xs font-medium text-[#e6f1fc]">Local Port to Expose</label>
                <span className="text-[10px] font-mono text-[#10b981] font-semibold">SSH Standard: 22</span>
              </div>
              <input
                type="number"
                min="1"
                max="65535"
                value={localPort}
                onChange={(e) => setLocalPort(e.target.value)}
                className="w-full px-3.5 py-2 bg-[#0c1b2c] border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none"
              />
              {Number(localPort) === 3000 && (
                <div className="text-xs text-[#ef4444] font-mono flex items-center gap-1.5 mt-1">
                  <PortGuardIcon size={12} />
                  <span>PORT 3000 LOCKED: AI Studio preview server is running on this port.</span>
                </div>
              )}
            </div>
          )}

          {/* Admin User & SSH Key Config */}
          {(selectedMode === 'full_setup' || selectedMode === 'install_openssh') && (
            <div className="space-y-4 pt-3 border-t border-[#1e334a]">
              <Checkbox
                checked={createAdmin}
                onChange={setCreateAdmin}
                label="Create Dedicated Sudo Admin User"
                description="Safer alternative to exposing root directly over public tunnels"
              />

              {createAdmin && (
                <div className="space-y-3 pl-3.5 border-l-2 border-[#1e334a]">
                  <div>
                    <label className="text-xs font-medium text-[#b5c7d8] block mb-1">Username</label>
                    <input
                      type="text"
                      value={username}
                      onChange={(e) => setUsername(e.target.value)}
                      className="w-full px-3.5 py-2 bg-[#071320] border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none"
                      placeholder="admin"
                    />
                  </div>

                  <div>
                    <label className="text-xs font-medium text-[#b5c7d8] block mb-1">SSH Public Key (.pub)</label>
                    <textarea
                      rows={2}
                      value={pubkey}
                      onChange={(e) => setPubkey(e.target.value)}
                      className="w-full px-3.5 py-2 bg-[#071320] border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none resize-none"
                      placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... user@laptop"
                    />
                    <p className="text-[11px] text-[#7891a8] mt-0.5">
                      Deduplicated automatically so authorized_keys is never corrupted across runs.
                    </p>
                  </div>
                </div>
              )}
            </div>
          )}

          <div className="flex justify-between pt-4 border-t border-[#1e334a]">
            <Button
              variant="secondary"
              size="md"
              onClick={() => setStep('select')}
            >
              Back
            </Button>
            <Button
              variant="primary"
              size="md"
              onClick={handleNextToReview}
              rightIcon={<ChevronRight className="w-3.5 h-3.5" />}
            >
              Review Directives
            </Button>
          </div>
        </GlassCard>
      )}

      {/* STEP 3: Review & Confirmation */}
      {step === 'review' && (
        <GlassCard variant="default" className="space-y-5">
          <div className="border-b border-[#1e334a] pb-3">
            <h3 className="text-sm font-semibold text-[#e6f1fc]">Pre-Flight Review & Safeguard Gate</h3>
            <p className="text-xs text-[#b5c7d8]">Review planned system operations before initiating execution.</p>
          </div>

          <div className="space-y-3 font-mono text-xs">
            <div className="p-3 bg-[#071320] rounded border border-[#1e334a] space-y-1">
              <div className="text-[#7891a8]">TARGET OPERATION:</div>
              <div className="text-[#00e5ff] font-semibold">{selectedMode}</div>
            </div>

            <div className="p-3 bg-[#071320] rounded border border-[#1e334a] space-y-1">
              <div className="text-[#7891a8]">TARGET PORT:</div>
              <div className="text-[#10b981] font-semibold">{localPort} (TCP) — Port 3000 Shielded</div>
            </div>

            {domain && (
              <div className="p-3 bg-[#071320] rounded border border-[#1e334a] space-y-1">
                <div className="text-[#7891a8]">PUBLIC INGRESS HOSTNAME:</div>
                <div className="text-[#38bdf8] font-semibold">{fullHostname}</div>
              </div>
            )}

            <div className="p-3 bg-[#071320] rounded border border-[#1e334a] space-y-1">
              <div className="text-[#7891a8]">EXECUTION MODE:</div>
              <div className="text-[#10b981] font-semibold">LIVE PRODUCTION EXECUTION</div>
            </div>
          </div>

          <div className="p-3.5 bg-[#00e5ff]/10 border border-[#00e5ff]/30 rounded text-xs text-[#e6f1fc] space-y-1.5 backdrop-blur-md">
            <span className="font-semibold block text-[#00e5ff]">Safety Guarantees:</span>
            <ul className="list-disc pl-4 space-y-0.5 text-[11px] text-[#b5c7d8]">
              <li>sshd_config is backed up automatically before any directive update.</li>
              <li>Syntax validation is tested via `sshd -t` prior to reloading services.</li>
              <li>Existing port 3000 process is protected from conflict or override.</li>
            </ul>
          </div>

          <div className="flex justify-between pt-4 border-t border-[#1e334a]">
            <Button
              variant="secondary"
              size="md"
              onClick={() => setStep('configure')}
            >
              Back
            </Button>
            <Button
              variant="primary"
              size="md"
              onClick={handleStartExecution}
              disabled={isSubmitting}
              isLoading={isSubmitting}
              leftIcon={<Play className="w-3.5 h-3.5 fill-current" />}
            >
              Confirm & Execute Job
            </Button>
          </div>
        </GlassCard>
      )}

      {/* STEP 4: Live Execution Monitor */}
      {(step === 'running' || isJobRunning) && activeJob && (
        <GlassCard variant="default" className="space-y-4">
          <div className="flex items-center justify-between border-b border-[#1e334a] pb-3">
            <div>
              <div className="flex items-center gap-2">
                <h3 className="text-sm font-semibold text-[#e6f1fc]">{activeJob.title}</h3>
                <span className={`text-[11px] font-mono px-2 py-0.5 rounded uppercase font-semibold ${
                  activeJob.status === 'completed'
                    ? 'bg-[#10b981]/20 text-[#10b981]'
                    : activeJob.status === 'failed'
                    ? 'bg-[#ef4444]/20 text-[#ef4444]'
                    : 'bg-[#00e5ff]/20 text-[#00e5ff] animate-pulse'
                }`}>
                  {activeJob.status}
                </span>
              </div>
              <p className="text-xs font-mono text-[#b5c7d8] mt-1">{activeJob.progressMessage}</p>
            </div>

            {activeJob.status === 'running' && (
              <Button
                variant="destructive"
                size="sm"
                onClick={() => onJobCancelled(activeJob.id)}
                leftIcon={<XOctagon className="w-3.5 h-3.5" />}
              >
                Cancel Task
              </Button>
            )}
          </div>

          {/* Real-time terminal log viewer */}
          <div className="bg-[#030d18] border border-[#1e334a] rounded p-3 font-mono text-xs max-h-80 overflow-y-auto space-y-1">
            {activeJob.logs.length === 0 ? (
              <div className="text-[#7891a8] italic">Awaiting process stream...</div>
            ) : (
              activeJob.logs.map((log) => (
                <div key={log.id} className="flex items-start gap-2 leading-relaxed">
                  <span className="text-[#475569] text-[10px] shrink-0">
                    {new Date(log.timestamp).toLocaleTimeString()}
                  </span>
                  <span
                    className={`shrink-0 text-[10px] px-1 rounded uppercase font-semibold ${
                      log.level === 'ok'
                        ? 'text-[#10b981] bg-[#10b981]/10'
                        : log.level === 'warn'
                        ? 'text-[#f59e0b] bg-[#f59e0b]/10'
                        : log.level === 'error'
                        ? 'text-[#ef4444] bg-[#ef4444]/10'
                        : 'text-[#00e5ff] bg-[#00e5ff]/10'
                    }`}
                  >
                    {log.level}
                  </span>
                  <span className="text-[#e6f1fc] break-all">{log.message}</span>
                </div>
              ))
            )}
          </div>

          {/* Completion summary & connection command */}
          {activeJob.status === 'completed' && (
            <div className="p-4 bg-[#10b981]/10 border border-[#10b981]/30 rounded space-y-2 backdrop-blur-md">
              <div className="flex items-center gap-2 text-xs font-semibold text-[#10b981]">
                <CheckCircle2 className="w-4 h-4" />
                <span>Execution Succeeded</span>
              </div>
              <p className="text-xs text-[#b5c7d8]">
                Connect to your remote SSH server using the verified command below:
              </p>
              <div className="p-3 bg-[#030d18] rounded border border-[#1e334a] flex items-center justify-between font-mono text-xs text-[#00e5ff]">
                <code className="break-all">{connectionCmd}</code>
                <button
                  onClick={() => {
                    navigator.clipboard.writeText(connectionCmd);
                    setCopiedCmd(true);
                    setTimeout(() => setCopiedCmd(false), 2000);
                  }}
                  className="ml-2 p-1.5 hover:bg-[#112234] rounded text-[#b5c7d8] hover:text-[#00e5ff] shrink-0 cursor-pointer"
                  title="Copy command"
                >
                  {copiedCmd ? <Check className="w-4 h-4 text-[#10b981]" /> : <Copy className="w-4 h-4" />}
                </button>
              </div>
            </div>
          )}

          <div className="flex justify-end pt-2">
            <Button
              variant="secondary"
              size="sm"
              onClick={() => setStep('select')}
            >
              Start Another Operation
            </Button>
          </div>
        </GlassCard>
      )}
    </div>
  );
};
