import React, { useState, useEffect, useCallback } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Sidebar } from './components/Sidebar';
import { Header } from './components/Header';
import { Drawer } from './components/Drawer';
import { DashboardOverview } from './components/DashboardOverview';
import { InstallWizard } from './components/InstallWizard';
import { SshManager } from './components/SshManager';
import { TunnelManager } from './components/TunnelManager';
import { LogStreamViewer } from './components/LogStreamViewer';
import { SystemStatusResponse, JobState } from './types';
import { fetchSystemStatus, cancelJob, fetchJob } from './api';
import { AlertCircle, RotateCw } from 'lucide-react';
import { Button } from './components/ui/Button';
import { PortGuardIcon, CyberKeyholeIcon } from './components/ui/Icons';

export default function App() {
  const [status, setStatus] = useState<SystemStatusResponse | null>(null);
  const [currentTab, setCurrentTab] = useState('dashboard');
  const [isSidebarCollapsed, setIsSidebarCollapsed] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [fetchError, setFetchError] = useState<string | null>(null);

  // Drawer state
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [drawerTitle, setDrawerTitle] = useState('');
  const [drawerCategory, setDrawerCategory] = useState<'client' | 'ingress' | 'safeguard' | 'daemon'>('client');
  const [drawerData, setDrawerData] = useState<any>(null);

  const loadStatus = useCallback(async (showIndicator = false) => {
    if (showIndicator) setIsRefreshing(true);
    try {
      const data = await fetchSystemStatus();
      setStatus(data);
      setFetchError(null);
    } catch (err: any) {
      setFetchError(err.message || 'Unable to connect to backend control plane.');
    } finally {
      setIsLoading(false);
      setIsRefreshing(false);
    }
  }, []);

  useEffect(() => {
    loadStatus();
    const interval = setInterval(() => {
      loadStatus();
    }, 5000);
    return () => clearInterval(interval);
  }, [loadStatus]);

  // Active job polling
  useEffect(() => {
    if (!status?.activeJob) return;
    if (
      status.activeJob.status === 'completed' ||
      status.activeJob.status === 'failed' ||
      status.activeJob.status === 'cancelled'
    ) {
      return;
    }

    const jobPoller = setInterval(async () => {
      try {
        const updated = await fetchJob(status.activeJob!.id);
        setStatus((prev) => (prev ? { ...prev, activeJob: updated } : null));
      } catch {
        // ignore transient errors
      }
    }, 1500);

    return () => clearInterval(jobPoller);
  }, [status?.activeJob]);

  const handleJobStarted = (job: JobState) => {
    setStatus((prev) => (prev ? { ...prev, activeJob: job } : null));
  };

  const handleCancelJob = async (jobId: string) => {
    try {
      await cancelJob(jobId);
      loadStatus();
    } catch (err: any) {
      console.error(err);
    }
  };

  const handleOpenTopologyDrawer = (nodeType: 'client' | 'ingress' | 'safeguard' | 'daemon', data?: any) => {
    const titles = {
      client: 'Remote Client Connection Directives',
      ingress: 'Ingress Cloud & Tunnel Parameters',
      safeguard: 'Port 3000 Hardware Isolation Gate',
      daemon: 'OpenSSH Daemon Specifications'
    };
    setDrawerCategory(nodeType);
    setDrawerTitle(titles[nodeType]);
    setDrawerData(data);
    setDrawerOpen(true);
  };

  const handleOpenSafeguard = () => {
    handleOpenTopologyDrawer('safeguard', status?.protectedInfra);
  };

  if (isLoading && !status) {
    return (
      <div className="min-h-screen bg-[#030d18] flex items-center justify-center p-4">
        <div className="flex flex-col items-center gap-3.5">
          <div className="w-10 h-10 rounded-full border-2 border-[#00e5ff] border-t-transparent animate-spin shadow-[0_0_20px_rgba(0,229,255,0.4)]" />
          <span className="font-mono text-xs text-[#b5c7d8] tracking-widest uppercase font-semibold">
            Initializing SSH.JC Control Plane...
          </span>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-[#030d18] text-[#e6f1fc] flex font-sans antialiased selection:bg-[#00e5ff]/25 selection:text-[#c3f5ff]">
      {/* 1. Collapsible Sidebar Command Center */}
      <Sidebar
        currentTab={currentTab}
        onSelectTab={setCurrentTab}
        isCollapsed={isSidebarCollapsed}
        onToggleCollapse={() => setIsSidebarCollapsed((prev) => !prev)}
        status={status}
      />

      {/* 2. Main Content Viewport */}
      <div className="flex-1 flex flex-col min-w-0 min-h-screen overflow-x-hidden">
        {/* Global Header Bar */}
        <Header
          currentTab={currentTab}
          onRefresh={() => loadStatus(true)}
          isRefreshing={isRefreshing}
          activeJob={status?.activeJob || null}
          onCancelJob={handleCancelJob}
          onOpenSafeguard={handleOpenSafeguard}
        />

        {/* Viewport Content */}
        <main className="flex-1 p-4 sm:p-6 lg:p-8 max-w-7xl w-full mx-auto">
          {fetchError && (
            <motion.div
              initial={{ opacity: 0, y: -5 }}
              animate={{ opacity: 1, y: 0 }}
              className="p-4 mb-6 bg-[#ef4444]/15 border border-[#ef4444]/40 rounded text-xs text-[#ffdad6] flex items-start justify-between gap-3 font-mono backdrop-blur-md"
            >
              <div className="flex items-center gap-2.5">
                <AlertCircle className="w-4 h-4 text-[#ef4444] shrink-0" />
                <span>{fetchError} (Check backend server on port 3000)</span>
              </div>
              <Button
                variant="destructive"
                size="sm"
                onClick={() => loadStatus(true)}
              >
                Retry
              </Button>
            </motion.div>
          )}

          {status && (
            <AnimatePresence mode="wait">
              <motion.div
                key={currentTab}
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -8 }}
                transition={{ duration: 0.2 }}
              >
                {currentTab === 'dashboard' && (
                  <DashboardOverview
                    status={status}
                    onNavigate={setCurrentTab}
                    onRefresh={() => loadStatus(true)}
                    isRefreshing={isRefreshing}
                    onCancelJob={handleCancelJob}
                    onSelectTopologyNode={handleOpenTopologyDrawer}
                  />
                )}

                {currentTab === 'wizard' && (
                  <InstallWizard
                    status={status}
                    activeJob={status.activeJob}
                    onJobStarted={handleJobStarted}
                    onJobCancelled={handleCancelJob}
                  />
                )}

                {currentTab === 'ssh' && (
                  <SshManager
                    sshStatus={status.ssh}
                    onJobStarted={handleJobStarted}
                    onRefresh={() => loadStatus(true)}
                  />
                )}

                {currentTab === 'tunnels' && (
                  <TunnelManager
                    status={status}
                    onJobStarted={handleJobStarted}
                    onRefresh={() => loadStatus(true)}
                  />
                )}

                {currentTab === 'logs' && <LogStreamViewer />}
              </motion.div>
            </AnimatePresence>
          )}
        </main>

        {/* Minimal Persistent Command Line Footer */}
        <footer className="border-t border-[#1e334a] bg-[#051424]/90 backdrop-blur-md px-6 py-3.5 text-xs font-mono text-[#7891a8] flex flex-col sm:flex-row items-center justify-between gap-2.5">
          <div className="flex items-center gap-2">
            <CyberKeyholeIcon size={14} className="text-[#00e5ff]" />
            <span className="text-[#00e5ff] font-semibold">SSH.JC</span>
            <span>·</span>
            <span>Command Center</span>
            <span>·</span>
            <span>JCVERSA/Ssh.jc Verified Integration</span>
          </div>
          <div className="flex items-center gap-2 text-[11px]">
            <PortGuardIcon size={13} className="text-[#10b981]" />
            <span className="text-[#10b981] font-semibold">Port 3000 Ingress Shielded</span>
          </div>
        </footer>
      </div>

      {/* 3. Kinetic Sliding Telemetry Drawer */}
      <Drawer
        isOpen={drawerOpen}
        onClose={() => setDrawerOpen(false)}
        title={drawerTitle}
        category={drawerCategory}
        data={drawerData}
      />
    </div>
  );
}
