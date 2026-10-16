import React from 'react';
import { motion, HTMLMotionProps } from 'motion/react';

export interface GlassCardProps extends HTMLMotionProps<'div'> {
  variant?: 'default' | 'elevated' | 'interactive' | 'accent' | 'critical';
  children: React.ReactNode;
  className?: string;
}

export const GlassCard: React.FC<GlassCardProps> = ({
  variant = 'default',
  children,
  className = '',
  ...props
}) => {
  const variantStyles = {
    default:
      'bg-[#0c1b2c]/80 backdrop-blur-xl border border-[#1e334a] shadow-sm',
    elevated:
      'bg-[#112234]/85 backdrop-blur-2xl border border-[#243a52] shadow-[0_12px_32px_rgba(0,0,0,0.45)]',
    interactive:
      'bg-[#0c1b2c]/80 hover:bg-[#112234] backdrop-blur-xl border border-[#1e334a] hover:border-[#00e5ff]/50 shadow-sm hover:shadow-[0_0_20px_rgba(0,229,255,0.15)] transition-all cursor-pointer',
    accent:
      'bg-[#0c1b2c]/90 backdrop-blur-xl border border-[#00e5ff]/40 shadow-[0_0_20px_rgba(0,229,255,0.12)]',
    critical:
      'bg-[#0c1b2c]/90 backdrop-blur-xl border border-[#ef4444]/40 shadow-[0_0_20px_rgba(239,68,68,0.15)]'
  };

  return (
    <motion.div
      className={`rounded p-5 relative overflow-hidden ${variantStyles[variant]} ${className}`}
      {...props}
    >
      {children}
    </motion.div>
  );
};
