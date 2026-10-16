import React from 'react';
import { Lock, ShieldAlert, CheckCircle2, Info } from 'lucide-react';
import { ProtectedInfrastructure } from '../types';

interface ProtectedInfraBannerProps {
  infra: ProtectedInfrastructure;
}

export const ProtectedInfraBanner: React.FC<ProtectedInfraBannerProps> = ({ infra }) => {
  return (
    <div className="bg-[#0d1c2d] border border-[#273647] border-l-2 border-l-[#00e5ff] rounded p-4 mb-6 relative overflow-hidden shadow-sm">
      <div className="flex flex-col md:flex-row items-start md:items-center justify-between gap-4">
        <div className="flex items-start gap-3">
          <div className="w-9 h-9 rounded bg-[#010f1f] border border-[#00e5ff]/30 flex items-center justify-center text-[#00e5ff] shrink-0 mt-0.5">
            <Lock className="w-5 h-5" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h2 className="text-sm font-semibold text-[#f1f5f9] tracking-tight">
                PROTECTED INFRASTRUCTURE GUARD: PORT {infra.port}
              </h2>
              <span className="font-mono text-[11px] px-2 py-0.5 rounded bg-[#00e5ff]/10 text-[#00e5ff] border border-[#00e5ff]/30 uppercase font-medium">
                Locked & Shielded
              </span>
            </div>
            <p className="text-xs text-[#bac9cc] mt-1 leading-relaxed max-w-3xl">
              {infra.reason} The control plane strictly validates and prohibits SSH.JC tunnels from binding or overriding port {infra.port}.
            </p>
          </div>
        </div>

        <div className="flex items-center gap-4 text-xs font-mono shrink-0 self-end md:self-center bg-[#010f1f] px-3 py-2 rounded border border-[#273647]">
          <div>
            <span className="text-[#849396] block text-[10px]">PROCESS</span>
            <span className="text-[#d4e4fa] font-medium">{infra.process}</span>
          </div>
          <div className="h-6 w-px bg-[#273647]" />
          <div>
            <span className="text-[#849396] block text-[10px]">PID</span>
            <span className="text-[#00e5ff] font-medium">{infra.pid || 'Active'}</span>
          </div>
          <div className="h-6 w-px bg-[#273647]" />
          <div>
            <span className="text-[#849396] block text-[10px]">TARGET SSH PORT</span>
            <span className="text-[#10b981] font-medium">22 (Isolated)</span>
          </div>
        </div>
      </div>
    </div>
  );
};
