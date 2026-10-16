import React from 'react';
import { motion, HTMLMotionProps } from 'motion/react';
import { RotateCw } from 'lucide-react';

export interface ButtonProps extends Omit<HTMLMotionProps<'button'>, 'children'> {
  variant?: 'primary' | 'secondary' | 'destructive' | 'ghost' | 'outline' | 'glass';
  size?: 'sm' | 'md' | 'lg';
  isLoading?: boolean;
  leftIcon?: React.ReactNode;
  rightIcon?: React.ReactNode;
  children: React.ReactNode;
}

export const Button: React.FC<ButtonProps> = ({
  variant = 'secondary',
  size = 'md',
  isLoading = false,
  leftIcon,
  rightIcon,
  children,
  disabled,
  className = '',
  ...props
}) => {
  const sizeStyles = {
    sm: 'px-2.5 py-1 text-xs gap-1.5 h-8',
    md: 'px-3.5 py-1.5 text-xs gap-2 h-9',
    lg: 'px-5 py-2.5 text-sm gap-2.5 h-11'
  };

  const variantStyles = {
    primary:
      'bg-gradient-to-r from-[#00e5ff] to-[#38bdf8] hover:from-[#38bdf8] hover:to-[#00e5ff] text-[#030d18] font-semibold border border-transparent shadow-[0_0_15px_rgba(0,229,255,0.3)] hover:shadow-[0_0_24px_rgba(0,229,255,0.5)]',
    secondary:
      'bg-[#0c1b2c]/85 hover:bg-[#112234] text-[#e6f1fc] border border-[#1e334a] hover:border-[#00e5ff]/50 backdrop-blur-xl shadow-sm hover:shadow-[0_0_12px_rgba(0,229,255,0.15)]',
    destructive:
      'bg-[#ef4444]/15 hover:bg-[#ef4444]/25 text-[#ffdad6] border border-[#ef4444]/40 hover:border-[#ef4444] shadow-[0_0_12px_rgba(239,68,68,0.2)]',
    ghost:
      'bg-transparent hover:bg-[#0c1b2c]/60 text-[#b5c7d8] hover:text-[#e6f1fc] border border-transparent',
    outline:
      'bg-transparent hover:bg-[#00e5ff]/10 text-[#00e5ff] border border-[#00e5ff]/40 hover:border-[#00e5ff] shadow-[0_0_10px_rgba(0,229,255,0.15)]',
    glass:
      'bg-white/[0.04] hover:bg-white/[0.08] text-[#e6f1fc] border border-white/10 hover:border-[#00e5ff]/40 backdrop-blur-2xl shadow-sm'
  };

  const isDisabled = disabled || isLoading;

  return (
    <motion.button
      whileTap={!isDisabled ? { scale: 0.97 } : undefined}
      whileHover={!isDisabled ? { y: -1 } : undefined}
      disabled={isDisabled}
      className={`relative inline-flex items-center justify-center font-mono rounded select-none transition-all focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#00e5ff] focus-visible:ring-offset-2 focus-visible:ring-offset-[#030d18] ${sizeStyles[size]} ${variantStyles[variant]} ${
        isDisabled ? 'opacity-50 cursor-not-allowed pointer-events-none' : 'cursor-pointer'
      } ${className}`}
      {...props}
    >
      {isLoading ? (
        <RotateCw className="w-3.5 h-3.5 animate-spin text-current shrink-0" />
      ) : (
        leftIcon && <span className="shrink-0">{leftIcon}</span>
      )}
      <span className="truncate">{children}</span>
      {!isLoading && rightIcon && <span className="shrink-0">{rightIcon}</span>}
    </motion.button>
  );
};
