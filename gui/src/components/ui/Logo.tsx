import React from 'react';
import { motion } from 'motion/react';

interface LogoProps {
  variant?: 'icon' | 'horizontal' | 'stacked';
  size?: 'sm' | 'md' | 'lg' | 'xl';
  showGlow?: boolean;
  pulse?: boolean;
  className?: string;
}

export const Logo: React.FC<LogoProps> = ({
  variant = 'horizontal',
  size = 'md',
  showGlow = true,
  pulse = false,
  className = ''
}) => {
  const sizeMap = {
    sm: { icon: 26, fontTitle: 'text-xs', fontSub: 'text-[9px]' },
    md: { icon: 36, fontTitle: 'text-sm', fontSub: 'text-[10px]' },
    lg: { icon: 48, fontTitle: 'text-base', fontSub: 'text-xs' },
    xl: { icon: 60, fontTitle: 'text-xl', fontSub: 'text-xs' }
  };

  const { icon: iconSize, fontTitle, fontSub } = sizeMap[size];

  // The Cybernetic Keyhole SVG:
  // Combines concentric hexagonal tunnel rings, an encrypted keyhole portal,
  // and directional gateway vectors with cryptographic bit teeth.
  const IconSvg = (
    <div className={`relative flex items-center justify-center shrink-0 ${className}`}>
      {showGlow && (
        <div
          className={`absolute inset-0 rounded-full bg-[#00e5ff]/25 blur-md pointer-events-none ${
            pulse ? 'animate-pulse' : ''
          }`}
          style={{ width: iconSize, height: iconSize }}
        />
      )}
      <svg
        width={iconSize}
        height={iconSize}
        viewBox="0 0 64 64"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        className="relative z-10 transition-transform duration-300 hover:scale-105 select-none"
      >
        <defs>
          <linearGradient id="cyberGradient" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stopColor="#00e5ff" />
            <stop offset="45%" stopColor="#38bdf8" />
            <stop offset="100%" stopColor="#818cf8" />
          </linearGradient>
          <linearGradient id="innerGlassGlow" x1="0%" y1="100%" x2="100%" y2="0%">
            <stop offset="0%" stopColor="#00e5ff" stopOpacity="0.35" />
            <stop offset="100%" stopColor="#0369a1" stopOpacity="0.08" />
          </linearGradient>
          <linearGradient id="coreKeyGlow" x1="0%" y1="0%" x2="0%" y2="100%">
            <stop offset="0%" stopColor="#00e5ff" />
            <stop offset="100%" stopColor="#0284c7" />
          </linearGradient>
          <filter id="cyberGlow" x="-20%" y="-20%" width="140%" height="140%">
            <feDropShadow dx="0" dy="0" stdDeviation="2.5" floodColor="#00e5ff" floodOpacity="0.6" />
          </filter>
        </defs>

        {/* Outer Hexagonal Conduit Ring */}
        <polygon
          points="32,4 56,18 56,46 32,60 8,46 8,18"
          stroke="url(#cyberGradient)"
          strokeWidth="2.5"
          strokeLinejoin="round"
          filter="url(#cyberGlow)"
        />

        {/* Concentric Tunnel Wave (Inner Hexagon with Glass Fill) */}
        <polygon
          points="32,12 48,22 48,42 32,52 16,42 16,22"
          stroke="#1e334a"
          strokeWidth="1.5"
          fill="url(#innerGlassGlow)"
        />

        {/* Keyhole Silhouette Center Portal */}
        {/* Upper Keyhole Circle with Precision Hairline */}
        <circle
          cx="32"
          cy="26"
          r="7"
          fill="#030d18"
          stroke="url(#cyberGradient)"
          strokeWidth="2"
        />

        {/* Keyhole Lower Tapered Channel */}
        <path
          d="M 27.5 30 L 26 43 L 38 43 L 36.5 30 Z"
          fill="#030d18"
          stroke="url(#cyberGradient)"
          strokeWidth="2"
          strokeLinejoin="round"
        />

        {/* Cryptographic Key Bit & Symmetrical Teeth */}
        <circle cx="32" cy="26" r="3" fill="#00e5ff" />
        <path
          d="M 32 30 V 41 M 32 35 H 35 M 32 38.5 H 36"
          stroke="#00e5ff"
          strokeWidth="1.8"
          strokeLinecap="round"
        />

        {/* Lateral Telemetry Conduit Ports */}
        <line x1="8" y1="32" x2="16" y2="32" stroke="#00e5ff" strokeWidth="2" strokeLinecap="round" />
        <line x1="48" y1="32" x2="56" y2="32" stroke="#00e5ff" strokeWidth="2" strokeLinecap="round" />

        {/* Ingress Synchronization Nodes */}
        <circle cx="32" cy="4" r="2.2" fill="#00e5ff" />
        <circle cx="32" cy="60" r="2.2" fill="#00e5ff" />
      </svg>
    </div>
  );

  if (variant === 'icon') {
    return IconSvg;
  }

  if (variant === 'stacked') {
    return (
      <div className={`flex flex-col items-center gap-2 select-none ${className}`}>
        {IconSvg}
        <div className="text-center font-mono">
          <div className={`${fontTitle} font-bold tracking-tight text-[#e6f1fc] flex items-center justify-center gap-1.5`}>
            <span>SSH.JC</span>
          </div>
          <div className={`${fontSub} tracking-widest text-[#00e5ff] uppercase font-semibold`}>
            CONTROL CENTER
          </div>
        </div>
      </div>
    );
  }

  // Horizontal Lockup
  return (
    <div className={`flex items-center gap-3 select-none ${className}`}>
      {IconSvg}
      <div className="font-mono">
        <div className={`${fontTitle} font-bold tracking-tight text-[#e6f1fc] flex items-center gap-2 leading-none`}>
          <span>SSH.JC</span>
          <span className="text-[10px] px-1.5 py-0.5 rounded bg-[#00e5ff]/15 text-[#00e5ff] border border-[#00e5ff]/35 font-semibold tracking-wider uppercase">
            CONTROL
          </span>
        </div>
        <div className={`${fontSub} text-[#7891a8] tracking-wider uppercase mt-1 leading-none font-medium`}>
          Secure Ingress System
        </div>
      </div>
    </div>
  );
};
