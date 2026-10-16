import React from 'react';
import { motion } from 'motion/react';

export interface CheckboxProps {
  id?: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
  label?: React.ReactNode;
  description?: string;
  disabled?: boolean;
  className?: string;
}

export const Checkbox: React.FC<CheckboxProps> = ({
  id,
  checked,
  onChange,
  label,
  description,
  disabled = false,
  className = ''
}) => {
  const inputId = id || `checkbox-${Math.random().toString(36).substring(2, 8)}`;

  return (
    <label
      htmlFor={inputId}
      className={`relative inline-flex items-start gap-3 select-none font-mono ${
        disabled ? 'opacity-50 cursor-not-allowed' : 'cursor-pointer group'
      } ${className}`}
    >
      {/* Hidden Native Input for accessibility & keyboard space-toggle */}
      <input
        type="checkbox"
        id={inputId}
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
        className="sr-only"
      />

      {/* Custom Sleek Glass Checkbox Box */}
      <div
        className={`w-4 h-4 rounded mt-0.5 shrink-0 flex items-center justify-center transition-all border backdrop-blur-md ${
          checked
            ? 'bg-gradient-to-br from-[#00e5ff] to-[#0284c7] border-[#00e5ff] shadow-[0_0_10px_rgba(0,229,255,0.45)]'
            : 'bg-[#071320]/90 border-[#1e334a] group-hover:border-[#00e5ff]/50 group-hover:bg-[#0c1b2c]'
        } group-focus-within:ring-2 group-focus-within:ring-[#00e5ff] group-focus-within:ring-offset-1 group-focus-within:ring-offset-[#030d18]`}
      >
        <svg
          viewBox="0 0 14 14"
          fill="none"
          xmlns="http://www.w3.org/2000/svg"
          className="w-3 h-3 text-[#030d18]"
        >
          <motion.path
            d="M 2.5 7 L 5.5 10 L 11.5 3.5"
            stroke="currentColor"
            strokeWidth="2.4"
            strokeLinecap="round"
            strokeLinejoin="round"
            initial={false}
            animate={{ pathLength: checked ? 1 : 0, opacity: checked ? 1 : 0 }}
            transition={{ duration: 0.18, ease: 'easeOut' }}
          />
        </svg>
      </div>

      {/* Label & Description Text */}
      {(label || description) && (
        <div className="text-xs">
          {label && (
            <span className="font-medium text-[#e6f1fc] group-hover:text-white transition-colors block leading-tight">
              {label}
            </span>
          )}
          {description && (
            <span className="text-[11px] text-[#7891a8] block mt-0.5 leading-snug">
              {description}
            </span>
          )}
        </div>
      )}
    </label>
  );
};
