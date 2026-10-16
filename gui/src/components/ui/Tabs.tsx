import React from 'react';
import { motion } from 'motion/react';

export interface TabItem {
  id: string;
  label: string;
  icon?: React.ReactNode;
  badge?: string | number;
}

export interface TabsProps {
  items: TabItem[];
  activeId: string;
  onChange: (id: string) => void;
  className?: string;
}

export const Tabs: React.FC<TabsProps> = ({
  items,
  activeId,
  onChange,
  className = ''
}) => {
  return (
    <div
      className={`inline-flex items-center gap-1 p-1 bg-[#071320]/90 backdrop-blur-md rounded border border-[#1e334a] font-mono text-xs ${className}`}
    >
      {items.map((tab) => {
        const isActive = tab.id === activeId;
        return (
          <button
            key={tab.id}
            type="button"
            onClick={() => onChange(tab.id)}
            className={`relative px-3.5 py-1.5 rounded font-medium transition-colors flex items-center gap-2 select-none z-10 ${
              isActive ? 'text-[#00e5ff]' : 'text-[#7891a8] hover:text-[#e6f1fc]'
            }`}
          >
            {isActive && (
              <motion.div
                layoutId="activeSubTabIndicator"
                className="absolute inset-0 bg-[#112234] border border-[#00e5ff]/40 rounded -z-10 shadow-sm"
                transition={{ type: 'spring', stiffness: 400, damping: 30 }}
              />
            )}
            {tab.icon && <span className="shrink-0">{tab.icon}</span>}
            <span>{tab.label}</span>
            {tab.badge !== undefined && (
              <span
                className={`text-[10px] px-1.5 py-0.2 rounded ${
                  isActive
                    ? 'bg-[#00e5ff]/20 text-[#00e5ff]'
                    : 'bg-[#182c42] text-[#7891a8]'
                }`}
              >
                {tab.badge}
              </span>
            )}
          </button>
        );
      })}
    </div>
  );
};
