import React, { useState, useEffect } from 'react';
import {
  Server,
  Key,
  Users,
  FileText,
  RotateCw,
  CheckCircle2,
  AlertTriangle,
  Plus,
  ShieldAlert,
  ShieldCheck
} from 'lucide-react';
import { SshStatus, JobState } from '../types';
import { fetchSshConfig, executeJob } from '../api';
import { Button } from './ui/Button';
import { Select } from './ui/Select';
import { Checkbox } from './ui/Checkbox';
import { GlassCard } from './ui/GlassCard';
import { Tabs } from './ui/Tabs';
import { BastionShieldIcon, SftpExchangeIcon } from './ui/Icons';

interface SshManagerProps {
  sshStatus: SshStatus;
  onJobStarted: (job: JobState) => void;
  onRefresh: () => void;
}

export const SshManager: React.FC<SshManagerProps> = ({
  sshStatus,
  onJobStarted,
  onRefresh
}) => {
  const [activeSubTab, setActiveSubTab] = useState<'access' | 'security' | 'config'>('access');
  const [configData, setConfigData] = useState<{ exists: boolean; content: string; backups: string[] } | null>(null);
  const [isLoadingConfig, setIsLoadingConfig] = useState(false);

  // New admin user state
  const [newUsername, setNewUsername] = useState('jcadmin');
  const [newPubkey, setNewPubkey] = useState('');
  const [disablePasswordAuth, setDisablePasswordAuth] = useState(false);
  const [isSubmittingUser, setIsSubmittingUser] = useState(false);

  // Security directives state
  const [targetPermitRoot, setTargetPermitRoot] = useState<'prohibit-password' | 'no' | 'yes'>(
    sshStatus.permitRootLogin === 'yes' ? 'yes' : 'prohibit-password'
  );
  const [targetPasswordAuth, setTargetPasswordAuth] = useState<'yes' | 'no'>(
    sshStatus.passwordAuthentication === 'yes' ? 'yes' : 'no'
  );

  const [feedbackMessage, setFeedbackMessage] = useState<{ type: 'ok' | 'error'; message: string } | null>(null);

  const loadConfig = async () => {
    setIsLoadingConfig(true);
    try {
      const data = await fetchSshConfig();
      setConfigData(data);
    } catch (err: any) {
      setFeedbackMessage({ type: 'error', message: err.message });
    } finally {
      setIsLoadingConfig(false);
    }
  };

  useEffect(() => {
    if (activeSubTab === 'config') {
      loadConfig();
    }
  }, [activeSubTab]);

  const handleCreateUser = async (e: React.FormEvent) => {
    e.preventDefault();
    setFeedbackMessage(null);

    if (!newUsername) {
      setFeedbackMessage({ type: 'error', message: 'Username is required.' });
      return;
    }

    if (newPubkey && !newPubkey.trim().startsWith('ssh-')) {
      setFeedbackMessage({ type: 'error', message: 'Public key format invalid. Expected OpenSSH key format (ssh-ed25519 or ssh-rsa).' });
      return;
    }

    setIsSubmittingUser(true);
    try {
      const job = await executeJob('configure_admin_user', {
        username: newUsername,
        pubkey: newPubkey.trim(),
        disablePasswordAuth
      });
      onJobStarted(job);
      setFeedbackMessage({ type: 'ok', message: `Job scheduled: Create admin user '${newUsername}'.` });
      setNewPubkey('');
    } catch (err: any) {
      setFeedbackMessage({ type: 'error', message: err.message });
    } finally {
      setIsSubmittingUser(false);
    }
  };

  const handleUpdateSecurity = async () => {
    setFeedbackMessage(null);
    try {
      const job = await executeJob('update_sshd_security', {
        permitRootLogin: targetPermitRoot,
        passwordAuthentication: targetPasswordAuth
      });
      onJobStarted(job);
      setFeedbackMessage({ type: 'ok', message: 'Updating sshd security directives with safe backup.' });
    } catch (err: any) {
      setFeedbackMessage({ type: 'error', message: err.message });
    }
  };

  const handleToggleSftp = async () => {
    setFeedbackMessage(null);
    try {
      const job = await executeJob('toggle_sftp', {});
      onJobStarted(job);
      setFeedbackMessage({ type: 'ok', message: 'Configuring SFTP subsystem directive...' });
    } catch (err: any) {
      setFeedbackMessage({ type: 'error', message: err.message });
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 pb-2 border-b border-[#1e334a]">
        <div>
          <h1 className="text-xl font-semibold tracking-tight text-[#e6f1fc] flex items-center gap-2.5">
            <BastionShieldIcon size={22} className="text-[#00e5ff]" />
            <span>OpenSSH Bastion & Security</span>
          </h1>
          <p className="text-xs text-[#b5c7d8] mt-0.5">
            Real daemon inspection, authorized_keys deduplication, and syntax validation.
          </p>
        </div>

        {/* Sliding Kinetic Tabs */}
        <Tabs
          items={[
            { id: 'access', label: 'Access & Users', icon: <Users className="w-3.5 h-3.5" /> },
            { id: 'security', label: 'Directives & SFTP', icon: <Server className="w-3.5 h-3.5" /> },
            { id: 'config', label: 'sshd_config View', icon: <FileText className="w-3.5 h-3.5" /> }
          ]}
          activeId={activeSubTab}
          onChange={(id) => setActiveSubTab(id as any)}
        />
      </div>

      {feedbackMessage && (
        <div
          className={`p-3.5 rounded text-xs flex items-center gap-2.5 border backdrop-blur-md ${
            feedbackMessage.type === 'ok'
              ? 'bg-[#10b981]/10 border-[#10b981]/30 text-[#a8ffd2]'
              : 'bg-[#ef4444]/10 border-[#ef4444]/30 text-[#ffb4ab]'
          }`}
        >
          {feedbackMessage.type === 'ok' ? (
            <CheckCircle2 className="w-4 h-4 text-[#10b981] shrink-0" />
          ) : (
            <AlertTriangle className="w-4 h-4 text-[#ef4444] shrink-0" />
          )}
          <span>{feedbackMessage.message}</span>
        </div>
      )}

      {/* SUBTAB 1: Access & Users */}
      {activeSubTab === 'access' && (
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <GlassCard variant="default" className="lg:col-span-2 space-y-4">
            <div className="flex items-center justify-between border-b border-[#1e334a] pb-3">
              <div>
                <h3 className="text-sm font-semibold text-[#e6f1fc]">Create Dedicated Admin User</h3>
                <p className="text-xs text-[#b5c7d8]">
                  Install.sh best practice: safer alternative to exposing root directly on a public tunnel.
                </p>
              </div>
              <span className="text-[11px] font-mono text-[#10b981] px-2 py-0.5 rounded bg-[#10b981]/10 border border-[#10b981]/30 font-semibold">
                Option 1 Flow
              </span>
            </div>

            <form onSubmit={handleCreateUser} className="space-y-4">
              <div>
                <label className="text-xs font-medium text-[#e6f1fc] block mb-1">Username</label>
                <input
                  type="text"
                  value={newUsername}
                  onChange={(e) => setNewUsername(e.target.value)}
                  className="w-full px-3.5 py-2.5 bg-[#071320]/80 border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none backdrop-blur-md transition-all focus:ring-1 focus:ring-[#00e5ff]"
                  placeholder="admin"
                  required
                />
              </div>

              <div>
                <label className="text-xs font-medium text-[#e6f1fc] block mb-1">
                  Public Key (OpenSSH Format)
                </label>
                <textarea
                  rows={3}
                  value={newPubkey}
                  onChange={(e) => setNewPubkey(e.target.value)}
                  className="w-full px-3.5 py-2.5 bg-[#071320]/80 border border-[#1e334a] focus:border-[#00e5ff] rounded text-xs font-mono text-[#e6f1fc] outline-none resize-none backdrop-blur-md transition-all focus:ring-1 focus:ring-[#00e5ff]"
                  placeholder="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... or ssh-rsa AAAAB3NzaC1yc2E..."
                />
                <p className="text-[11px] text-[#7891a8] mt-1">
                  Validated against standard OpenSSH key signature and deduplicated in authorized_keys.
                </p>
              </div>

              <div className="pt-1">
                <Checkbox
                  checked={disablePasswordAuth}
                  onChange={setDisablePasswordAuth}
                  label="Disable password authentication across all accounts once key is added"
                  description="Recommended security hardening against brute-force intrusion."
                />
              </div>

              <div className="pt-2 flex justify-end">
                <Button
                  type="submit"
                  variant="primary"
                  size="md"
                  disabled={isSubmittingUser}
                  isLoading={isSubmittingUser}
                  leftIcon={<Plus className="w-3.5 h-3.5" />}
                >
                  Create Admin & Bind Key
                </Button>
              </div>
            </form>
          </GlassCard>

          {/* Configured Accounts Inspector */}
          <GlassCard variant="default" className="space-y-4">
            <h3 className="text-sm font-semibold text-[#e6f1fc]">Configured Accounts</h3>
            <p className="text-xs text-[#b5c7d8]">Detected accounts with active authorized_keys.</p>

            <div className="space-y-2 font-mono text-xs">
              {sshStatus.configuredUsers.length === 0 ? (
                <div className="p-3 bg-[#071320] rounded border border-[#1e334a] text-[#7891a8] italic text-center">
                  No dedicated user keys configured yet.
                </div>
              ) : (
                sshStatus.configuredUsers.map((u) => (
                  <div key={u} className="p-2.5 bg-[#071320] rounded border border-[#1e334a] flex items-center justify-between">
                    <span className="text-[#e6f1fc] font-medium">{u}</span>
                    <span className="text-[10px] text-[#10b981] px-1.5 py-0.5 bg-[#10b981]/15 border border-[#10b981]/30 rounded font-semibold">
                      Key Configured
                    </span>
                  </div>
                ))
              )}
            </div>

            <div className="p-3 bg-[#071320] border border-[#1e334a] rounded space-y-1.5 text-xs text-[#7891a8]">
              <div className="text-[#b5c7d8] font-medium flex items-center gap-1.5">
                <SftpExchangeIcon size={14} className="text-[#00e5ff]" />
                <span>SFTP Subsystem:</span>
              </div>
              <div className="text-[#e6f1fc]">
                {sshStatus.sftpActive ? 'Active (Subsystem sftp internal-sftp)' : 'Inactive'}
              </div>
            </div>
          </GlassCard>
        </div>
      )}

      {/* SUBTAB 2: Security Directives & SFTP */}
      {activeSubTab === 'security' && (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <GlassCard variant="default" className="space-y-4">
            <h3 className="text-sm font-semibold text-[#e6f1fc]">Modify SSH Security Directives</h3>
            <p className="text-xs text-[#b5c7d8]">
              Changes are safely backed up to /etc/ssh/sshd_config.bak before writing, and verified via sshd -t.
            </p>

            <div className="space-y-4">
              {/* Custom Popover Select for PermitRootLogin */}
              <Select
                label="PermitRootLogin Directive"
                value={targetPermitRoot}
                onChange={(val) => setTargetPermitRoot(val as any)}
                options={[
                  {
                    value: 'prohibit-password',
                    label: 'prohibit-password (Key-Only)',
                    description: 'Allows root login only via cryptographic SSH keys. Recommended.',
                    badge: 'Recommended'
                  },
                  {
                    value: 'no',
                    label: 'no (Completely Disabled)',
                    description: 'Disables root login entirely. Best practice with dedicated admin user.',
                    badge: 'Hardened'
                  },
                  {
                    value: 'yes',
                    label: 'yes (Password Allowed)',
                    description: 'Allows password login for root. High security risk on public tunnels.',
                    badge: 'High Risk'
                  }
                ]}
              />

              {/* Custom Popover Select for PasswordAuthentication */}
              <Select
                label="PasswordAuthentication Directive"
                value={targetPasswordAuth}
                onChange={(val) => setTargetPasswordAuth(val as any)}
                options={[
                  {
                    value: 'no',
                    label: 'no (Public Keys Only)',
                    description: 'Enforces cryptographic key authentication. Immune to brute-force attacks.',
                    badge: 'Hardened'
                  },
                  {
                    value: 'yes',
                    label: 'yes (Password Allowed)',
                    description: 'Allows standard passwords. Convenient for quick initial testing.',
                    badge: 'Standard'
                  }
                ]}
              />

              <Button
                variant="primary"
                size="md"
                onClick={handleUpdateSecurity}
                className="w-full mt-2"
              >
                Apply Directives (with Backup)
              </Button>
            </div>
          </GlassCard>

          <GlassCard variant="default" className="space-y-4">
            <h3 className="text-sm font-semibold text-[#e6f1fc]">SFTP File Transfer Subsystem</h3>
            <p className="text-xs text-[#b5c7d8]">
              Enable or disable secure file transfers via FileZilla, WinSCP, Cyberduck, or sftp cli.
            </p>

            <div className="p-3 bg-[#071320] rounded border border-[#1e334a] space-y-2 text-xs font-mono">
              <div className="flex items-center justify-between">
                <span className="text-[#7891a8]">CURRENT SUBSYSTEM:</span>
                <span className={sshStatus.sftpActive ? 'text-[#10b981] font-semibold' : 'text-[#7891a8]'}>
                  {sshStatus.sftpActive ? 'Active' : 'Disabled'}
                </span>
              </div>
              <div className="text-[11px] text-[#7891a8]">
                Directive: Subsystem sftp /usr/lib/openssh/sftp-server
              </div>
            </div>

            <Button
              variant="secondary"
              size="md"
              onClick={handleToggleSftp}
              className="w-full"
              leftIcon={<SftpExchangeIcon size={14} className="text-[#00e5ff]" />}
            >
              {sshStatus.sftpActive ? 'Re-verify SFTP Subsystem' : 'Enable SFTP Subsystem'}
            </Button>
          </GlassCard>
        </div>
      )}

      {/* SUBTAB 3: sshd_config View */}
      {activeSubTab === 'config' && (
        <GlassCard variant="default" className="space-y-4">
          <div className="flex items-center justify-between border-b border-[#1e334a] pb-3">
            <div>
              <h3 className="text-sm font-semibold text-[#e6f1fc]">Host sshd_config Viewer</h3>
              <p className="text-xs text-[#b5c7d8]">Direct read-only inspection of /etc/ssh/sshd_config.</p>
            </div>

            <Button
              variant="secondary"
              size="sm"
              onClick={loadConfig}
              isLoading={isLoadingConfig}
              leftIcon={<RotateCw className="w-3.5 h-3.5" />}
            >
              Reload File
            </Button>
          </div>

          {isLoadingConfig ? (
            <div className="p-8 text-center text-xs font-mono text-[#7891a8] flex items-center justify-center gap-2">
              <RotateCw className="w-4 h-4 animate-spin text-[#00e5ff]" />
              <span>Inspecting sshd_config...</span>
            </div>
          ) : !configData?.exists ? (
            <div className="p-6 bg-[#071320] border border-[#1e334a] rounded text-xs text-[#7891a8] text-center">
              No /etc/ssh/sshd_config found. OpenSSH may not be installed yet. Use Option 1 or 2 in the Install Wizard.
            </div>
          ) : (
            <div className="space-y-3">
              <div className="p-4 bg-[#030d18] rounded border border-[#1e334a] font-mono text-xs text-[#b5c7d8] max-h-96 overflow-y-auto leading-relaxed">
                <pre>{configData.content}</pre>
              </div>

              {configData.backups.length > 0 && (
                <div className="p-3 bg-[#071320] border border-[#1e334a] rounded space-y-1 text-xs font-mono">
                  <span className="text-[#7891a8] block">Automatic Backups Preserved:</span>
                  <div className="space-y-0.5 text-[#00e5ff]">
                    {configData.backups.map((b) => (
                      <div key={b}>{b}</div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}
        </GlassCard>
      )}
    </div>
  );
};
