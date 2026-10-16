import React, { useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import {
  X,
  Copy,
  Check,
  Server,
  Globe,
  Radio,
  FileText
} from 'lucide-react';
import { Button } from './ui/Button';
import { GlassCard } from './ui/GlassCard';
import {
  PortGuardIcon,
  BastionShieldIcon,
  TunnelConduitIcon,
  SftpExchangeIcon,
  CyberKeyholeIcon
} from './ui/Icons';

interface DrawerProps {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  category: 'client' | 'ingress' | 'safeguard' | 'daemon';
  data: any;
}

export const Drawer: React.FC<DrawerProps> = ({
  isOpen,
  onClose,
  title,
  category,
  data
}) => {
  const [copiedId, setCopiedId] = useState<string | null>(null);

  const handleCopy = (text: string, id: string) => {
    navigator.clipboard.writeText(text);
    setCopiedId(id);
    setTimeout(() => setCopiedId(null), 2000);
  };

  return (
    <AnimatePresence>
      {isOpen && (
        <div className="fixed inset-0 z-50 overflow-hidden select-none">
          {/* Backdrop Blur */}
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            onClick={onClose}
            className="absolute inset-0 bg-[#030d18]/80 backdrop-blur-md transition-opacity cursor-pointer"
          />

          {/* Drawer Slide-in Container */}
          <div className="fixed inset-y-0 right-0 max-w-full flex pl-10">
            <motion.div
              initial={{ x: '100%' }}
              animate={{ x: 0 }}
              exit={{ x: '100%' }}
              transition={{ type: 'spring', stiffness: 350, damping: 32 }}
              className="w-screen max-w-md bg-[#0c1b2c]/95 backdrop-blur-2xl border-l border-[#1e334a] flex flex-col justify-between shadow-[0_0_50px_rgba(0,0,0,0.8)]"
            >
              {/* Drawer Header */}
              <div className="p-5 border-b border-[#1e334a] flex items-center justify-between bg-[#071320]/60">
                <div>
                  <span className="text-[10px] font-mono uppercase text-[#00e5ff] tracking-wider font-semibold">
                    TELEMETRY INSPECTOR
                  </span>
                  <h3 className="text-base font-semibold text-[#e6f1fc] tracking-tight mt-0.5">
                    {title}
                  </h3>
                </div>

                <button
                  onClick={onClose}
                  className="p-1.5 rounded hover:bg-[#112234] text-[#7891a8] hover:text-[#e6f1fc] transition-colors cursor-pointer"
                >
                  <X className="w-5 h-5" />
                </button>
              </div>

              {/* Drawer Content Body */}
              <div className="flex-1 p-5 overflow-y-auto space-y-5 text-xs font-mono">
                {/* 1. CLIENT CONNECTION COMMANDS */}
                {category === 'client' && (
                  <div className="space-y-4">
                    <p className="text-[#b5c7d8] leading-relaxed">
                      Connect to your remote OpenSSH instance using the official Cloudflare Access ProxyCommand:
                    </p>

                    <div className="space-y-2">
                      <span className="text-[#7891a8] text-[11px] block">A. Termux / Linux / macOS Command:</span>
                      <div className="p-3 bg-[#071320] border border-[#1e334a] rounded space-y-2">
                        <code className="text-[#00e5ff] block break-all">
                          ssh -o ProxyCommand="cloudflared access ssh --hostname {data?.hostname || 'ssh.example.com'}" {data?.user || 'admin'}@{data?.hostname || 'ssh.example.com'}
                        </code>
                        <div className="flex justify-end pt-1">
                          <Button
                            variant="secondary"
                            size="sm"
                            onClick={() => handleCopy(`ssh -o ProxyCommand="cloudflared access ssh --hostname ${data?.hostname || 'ssh.example.com'}" ${data?.user || 'admin'}@{data?.hostname || 'ssh.example.com'}`, 'ssh-client')}
                            leftIcon={copiedId === 'ssh-client' ? <Check className="w-3.5 h-3.5 text-[#10b981]" /> : <Copy className="w-3.5 h-3.5" />}
                          >
                            {copiedId === 'ssh-client' ? 'Copied' : 'Copy Command'}
                          </Button>
                        </div>
                      </div>
                    </div>

                    <div className="space-y-2">
                      <span className="text-[#7891a8] text-[11px] block">B. SFTP File Transfer Command:</span>
                      <div className="p-3 bg-[#071320] border border-[#1e334a] rounded space-y-2">
                        <code className="text-[#e6f1fc] block break-all">
                          sftp -o ProxyCommand="cloudflared access ssh --hostname {data?.hostname || 'ssh.example.com'}" {data?.user || 'admin'}@{data?.hostname || 'ssh.example.com'}
                        </code>
                        <div className="flex justify-end pt-1">
                          <Button
                            variant="secondary"
                            size="sm"
                            onClick={() => handleCopy(`sftp -o ProxyCommand="cloudflared access ssh --hostname ${data?.hostname || 'ssh.example.com'}" ${data?.user || 'admin'}@{data?.hostname || 'ssh.example.com'}`, 'sftp-client')}
                            leftIcon={copiedId === 'sftp-client' ? <Check className="w-3.5 h-3.5 text-[#10b981]" /> : <Copy className="w-3.5 h-3.5" />}
                          >
                            {copiedId === 'sftp-client' ? 'Copied' : 'Copy SFTP'}
                          </Button>
                        </div>
                      </div>
                    </div>

                    <div className="p-3 bg-[#071320] border border-[#1e334a] rounded text-[11px] text-[#7891a8] space-y-1">
                      <span className="text-[#b5c7d8] font-medium block">FileZilla / WinSCP Setup:</span>
                      <div>1. Protocol: SFTP (SSH File Transfer Protocol)</div>
                      <div>2. Host: {data?.hostname || 'ssh.example.com'}</div>
                      <div>3. User: {data?.user || 'admin'}</div>
                      <div>4. Proxy command: cloudflared access ssh --hostname %host</div>
                    </div>
                  </div>
                )}

                {/* 2. INGRESS TUNNEL PARAMETERS */}
                {category === 'ingress' && (
                  <div className="space-y-4">
                    <div className="p-3 bg-[#071320] border border-[#1e334a] rounded space-y-2">
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">Tunnel Identifier:</span>
                        <span className="text-[#00e5ff] font-semibold">{data?.name || 'ssh-sandbox'}</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">Provider:</span>
                        <span className="text-[#38bdf8] uppercase font-semibold">{data?.provider || 'cloudflared'}</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">Public Hostname:</span>
                        <span className="text-[#e6f1fc] font-medium">{data?.hostname || 'Dynamic Port (SaaS)'}</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">Running Mode:</span>
                        <span className="text-[#e6f1fc]">{data?.runMode || 'background'}</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">Process ID (PID):</span>
                        <span className="text-[#10b981] font-semibold">{data?.pid || 'Not Running'}</span>
                      </div>
                    </div>

                    {data?.logFile && (
                      <div className="space-y-1">
                        <span className="text-[#7891a8] text-[11px]">Log File Location:</span>
                        <div className="p-2 bg-[#071320] border border-[#1e334a] rounded text-[11px] break-all text-[#b5c7d8]">
                          {data.logFile}
                        </div>
                      </div>
                    )}
                  </div>
                )}

                {/* 3. HARDWARE PORT 3000 SAFEGUARD */}
                {category === 'safeguard' && (
                  <div className="space-y-4">
                    <div className="p-3.5 bg-[#ef4444]/15 border border-[#ef4444]/35 rounded space-y-2 text-[#ffdad6] backdrop-blur-md">
                      <div className="flex items-center gap-2 font-semibold text-[#ef4444]">
                        <PortGuardIcon size={16} />
                        <span>PORT 3000 HARDWARE ISOLATION GATE</span>
                      </div>
                      <p className="text-[11px] leading-relaxed text-[#ffb4ab]">
                        {data?.reason || 'Port 3000 is reserved for AI Studio and the active Cloudflare ingress. Reconfiguring or exposing port 3000 is strictly prohibited.'}
                      </p>
                    </div>

                    <div className="p-3 bg-[#071320] border border-[#1e334a] rounded space-y-2">
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">Locked Port:</span>
                        <span className="text-[#ef4444] font-semibold">3000 (TCP)</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">Active Process:</span>
                        <span className="text-[#e6f1fc] font-medium">{data?.process || 'Node.js / Vite Control Plane'}</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">PID:</span>
                        <span className="text-[#00e5ff] font-semibold">{data?.pid || 'Active'}</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">Status:</span>
                        <span className="text-[#ef4444] font-semibold">LOCKED & SHIELDED</span>
                      </div>
                    </div>

                    <div className="p-3 bg-[#071320] border border-[#1e334a] rounded text-[11px] text-[#7891a8] space-y-1">
                      <span className="text-[#b5c7d8] font-medium block">Safeguard Guarantees:</span>
                      <div>• Backend API returns HTTP 403 on any job attempting port 3000.</div>
                      <div>• SSH daemon runs isolated on port 22.</div>
                      <div>• Existing ingress tunnels remain untouched and preserved.</div>
                    </div>
                  </div>
                )}

                {/* 4. OPENSSH DAEMON SPECIFICATIONS */}
                {category === 'daemon' && (
                  <div className="space-y-4">
                    <div className="p-3 bg-[#071320] border border-[#1e334a] rounded space-y-2">
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">Listening Port:</span>
                        <span className="text-[#00e5ff] font-semibold">{data?.listeningPort || 22} (TCP)</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">PermitRootLogin:</span>
                        <span className="text-[#10b981] font-semibold">{data?.permitRootLogin || 'prohibit-password'}</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">PasswordAuthentication:</span>
                        <span className="text-[#f59e0b] font-semibold">{data?.passwordAuthentication || 'no'}</span>
                      </div>
                      <div className="flex items-center justify-between">
                        <span className="text-[#7891a8]">SFTP Subsystem:</span>
                        <span className={data?.sftpActive ? 'text-[#10b981] font-semibold' : 'text-[#7891a8]'}>
                          {data?.sftpActive ? 'Active' : 'Inactive'}
                        </span>
                      </div>
                    </div>

                    <div className="space-y-1">
                      <span className="text-[#7891a8] text-[11px]">Configured User Accounts:</span>
                      <div className="p-2.5 bg-[#071320] border border-[#1e334a] rounded space-y-1 text-[#e6f1fc]">
                        {data?.configuredUsers?.length > 0 ? (
                          data.configuredUsers.map((u: string) => (
                            <div key={u} className="flex items-center justify-between">
                              <span>{u}</span>
                              <span className="text-[10px] text-[#10b981] px-1.5 py-0.2 bg-[#10b981]/15 border border-[#10b981]/30 rounded font-semibold">
                                Key Configured
                              </span>
                            </div>
                          ))
                        ) : (
                          <div className="text-[#7891a8] italic">None detected</div>
                        )}
                      </div>
                    </div>
                  </div>
                )}
              </div>

              {/* Drawer Footer */}
              <div className="p-4 border-t border-[#1e334a] bg-[#071320]/80 flex items-center justify-between text-xs font-mono text-[#7891a8]">
                <span>SSH.JC Precision Guard</span>
                <Button variant="secondary" size="sm" onClick={onClose}>
                  Close
                </Button>
              </div>
            </motion.div>
          </div>
        </div>
      )}
    </AnimatePresence>
  );
};
