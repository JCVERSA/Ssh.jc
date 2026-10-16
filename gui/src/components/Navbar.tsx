import React from 'react';
import { ShieldCheck, ShieldAlert, Terminal, Lock } from 'lucide-react';

interface NavbarProps {
  currentTab: string;
  onSelectTab: (tab: string) => void;
  isPort3000Protected: boolean;
}

export const Navbar: React.FC<NavbarProps> = ({
  currentTab,
  onSelectTab,
  isPort3000Protected,
}) => {
  const navItems = [
    { id: 'dashboard', label: 'Dashboard' },
    { id: 'wizard', label: 'Install Wizard' },
    { id: 'ssh', label: 'SSH Management' },
    { id: 'tunnels', label: 'Tunnels' },
    { id: 'logs', label: 'Logs & Events' }
  ];

  return (
    <header className="sticky top-0 z-40 bg-[#051424]/95 backdrop-blur-sm border-b border-[#273647]">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between gap-8">
        {/* Zone 1: Brand Wordmark */}
        <div className="flex items-center gap-3 shrink-0">
          <div className="w-8 h-8 rounded bg-[#122131] border border-[#00e5ff]/40 flex items-center justify-center text-[#00e5ff]">
            <Terminal className="w-4 h-4" />
          </div>
          <span className="font-semibold text-base tracking-tight text-[#f1f5f9] whitespace-nowrap">
            SSH.JC CONTROL CENTER
          </span>
        </div>

        {/* Zone 2: Navigation Links */}
        <nav className="hidden md:flex items-center gap-1">
          {navItems.map((item) => {
            const isActive = currentTab === item.id;
            return (
              <button
                key={item.id}
                onClick={() => onSelectTab(item.id)}
                className={`px-3 py-1.5 text-xs font-medium rounded transition-all whitespace-nowrap ${
                  isActive
                    ? 'bg-[#122131] text-[#00e5ff] border border-[#00e5ff]/30 shadow-sm'
                    : 'text-[#bac9cc] hover:text-[#f1f5f9] hover:bg-[#0d1c2d]'
                }`}
              >
                {item.label}
              </button>
            );
          })}
        </nav>

        {/* Zone 3: Primary Status & Action */}
        <div className="flex items-center gap-3 shrink-0">
          <div
            className="flex items-center gap-1.5 px-2.5 py-1 bg-[#010f1f] border border-[#273647] rounded text-xs font-mono text-[#849396]"
            title="Console port is protected from tunnel conflicts"
          >
            <Lock className="w-3.5 h-3.5 text-[#00e5ff]" />
            <span className="hidden lg:inline text-[#bac9cc]">Console Port</span>
            <span className="text-[#00e5ff] font-semibold">LOCKED</span>
          </div>
        </div>
      </div>

      {/* Mobile Nav Rail */}
      <div className="md:hidden flex items-center justify-around px-2 py-1.5 bg-[#010f1f] border-t border-[#273647] overflow-x-auto">
        {navItems.map((item) => {
          const isActive = currentTab === item.id;
          return (
            <button
              key={item.id}
              onClick={() => onSelectTab(item.id)}
              className={`px-2.5 py-1 text-[11px] font-medium whitespace-nowrap rounded ${
                isActive ? 'text-[#00e5ff] bg-[#122131]' : 'text-[#849396]'
              }`}
            >
              {item.label}
            </button>
          );
        })}
      </div>
    </header>
  );
};
