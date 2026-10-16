import React from 'react';

export interface BadgeProps {
  variant?: 'active' | 'locked' | 'warning' | 'info' | 'neutral';
  pulse?: boolean;
  children: React.ReactNode;
  className?: string;
}

export const Badge: React.FC<BadgeProps> = ({
  variant = 'neutral',
  pulse = false,
  children,
  className = ''
}) => {
  const variantStyles = {
    active: 'bg-[#10b981]/15 text-[#10b981] border-[#10b981]/30',
    locked: 'bg-[#ef4444]/15 text-[#ef4444] border-[#ef4444]/30',
    warning: 'bg-[#f59e0b]/15 text-[#f59e0b] border-[#f59e0b]/30',
    info: 'bg-[#00e5ff]/15 text-[#00e5ff] border-[#00e5ff]/30',
    neutral: 'bg-[#122131] text-[#bac9cc] border-[#273647]'
  };

  const dotColors = {
    active: 'bg-[#10b981]',
    locked: 'bg-[#ef4444]',
    warning: 'bg-[#f59e0b]',
    info: 'bg-[#00e5ff]',
    neutral: 'bg-[#849396]'
  };

  return (
    <span
      className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-[10px] font-mono font-semibold tracking-wider uppercase border select-none ${variantStyles[variant]} ${className}`}
    >
      <span
        className={`w-1.5 h-1.5 rounded-full shrink-0 ${dotColors[variant]} ${
          pulse ? 'animate-pulse' : ''
        }`}
      />
      <span>{children}</span>
    </span>
  );
};
