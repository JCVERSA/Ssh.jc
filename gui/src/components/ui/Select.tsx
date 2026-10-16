import React, { useState, useRef, useEffect } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { ChevronDown, Check, Search, X } from 'lucide-react';

export interface SelectOption {
  value: string;
  label: string;
  description?: string;
  badge?: string;
  icon?: React.ReactNode;
}

export interface SelectProps {
  options: SelectOption[];
  value: string;
  onChange: (value: string) => void;
  label?: string;
  placeholder?: string;
  searchable?: boolean;
  disabled?: boolean;
  className?: string;
}

export const Select: React.FC<SelectProps> = ({
  options,
  value,
  onChange,
  label,
  placeholder = 'Select option...',
  searchable = true,
  disabled = false,
  className = ''
}) => {
  const [isOpen, setIsOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [highlightedIndex, setHighlightedIndex] = useState(0);

  const containerRef = useRef<HTMLDivElement>(null);
  const searchInputRef = useRef<HTMLInputElement>(null);

  const selectedOption = options.find((opt) => opt.value === value);

  const filteredOptions = options.filter(
    (opt) =>
      opt.label.toLowerCase().includes(searchQuery.toLowerCase()) ||
      (opt.description && opt.description.toLowerCase().includes(searchQuery.toLowerCase())) ||
      (opt.badge && opt.badge.toLowerCase().includes(searchQuery.toLowerCase()))
  );

  // Close on outside click
  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  // Focus search input when opening
  useEffect(() => {
    if (isOpen) {
      setSearchQuery('');
      setHighlightedIndex(0);
      if (searchable && searchInputRef.current) {
        setTimeout(() => searchInputRef.current?.focus(), 60);
      }
    }
  }, [isOpen, searchable]);

  // Keyboard navigation
  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (disabled) return;

    if (!isOpen) {
      if (e.key === 'Enter' || e.key === ' ' || e.key === 'ArrowDown') {
        e.preventDefault();
        setIsOpen(true);
      }
      return;
    }

    if (e.key === 'Escape') {
      e.preventDefault();
      setIsOpen(false);
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      setHighlightedIndex((prev) => (prev < filteredOptions.length - 1 ? prev + 1 : 0));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setHighlightedIndex((prev) => (prev > 0 ? prev - 1 : filteredOptions.length - 1));
    } else if (e.key === 'Enter') {
      e.preventDefault();
      if (filteredOptions[highlightedIndex]) {
        onChange(filteredOptions[highlightedIndex].value);
        setIsOpen(false);
      }
    } else if (e.key === 'Tab') {
      setIsOpen(false);
    }
  };

  return (
    <div className={`relative space-y-1.5 font-mono ${className}`} ref={containerRef}>
      {label && (
        <label className="text-xs font-medium text-[#b5c7d8] block select-none">
          {label}
        </label>
      )}

      {/* Main Trigger Button */}
      <button
        type="button"
        role="combobox"
        aria-expanded={isOpen}
        disabled={disabled}
        onClick={() => setIsOpen(!isOpen)}
        onKeyDown={handleKeyDown}
        className={`w-full px-3.5 py-2.5 bg-[#071320]/80 hover:bg-[#0c1b2c] border rounded text-xs text-left flex items-center justify-between gap-2.5 transition-all focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#00e5ff] backdrop-blur-md ${
          isOpen
            ? 'border-[#00e5ff] ring-1 ring-[#00e5ff]/40 shadow-[0_0_15px_rgba(0,229,255,0.2)]'
            : 'border-[#1e334a] hover:border-[#2f4d6d]'
        } ${disabled ? 'opacity-50 cursor-not-allowed' : 'cursor-pointer'}`}
      >
        <div className="flex items-center gap-2 truncate">
          {selectedOption?.icon && <span className="text-[#00e5ff] shrink-0">{selectedOption.icon}</span>}
          <span className="truncate text-[#e6f1fc]">
            {selectedOption ? selectedOption.label : <span className="text-[#7891a8]">{placeholder}</span>}
          </span>
        </div>

        <div className="flex items-center gap-1.5 shrink-0">
          {selectedOption?.badge && (
            <span className="text-[10px] px-1.5 py-0.5 rounded bg-[#00e5ff]/10 text-[#00e5ff] border border-[#00e5ff]/25 font-semibold">
              {selectedOption.badge}
            </span>
          )}
          <motion.span
            animate={{ rotate: isOpen ? 180 : 0 }}
            transition={{ duration: 0.2, ease: 'easeInOut' }}
            className="text-[#7891a8]"
          >
            <ChevronDown className="w-3.5 h-3.5" />
          </motion.span>
        </div>
      </button>

      {/* Popover Dropdown Menu */}
      <AnimatePresence>
        {isOpen && (
          <motion.div
            initial={{ opacity: 0, y: -6, scale: 0.97 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: -6, scale: 0.97 }}
            transition={{ duration: 0.16, ease: 'easeOut' }}
            className="absolute z-50 left-0 right-0 mt-1 bg-[#0c1b2c]/95 backdrop-blur-2xl border border-[#1e334a] rounded shadow-[0_16px_40px_rgba(0,0,0,0.7)] overflow-hidden py-1 ring-1 ring-[#00e5ff]/20"
          >
            {/* Search Filter Input (if searchable and > 2 items) */}
            {searchable && options.length > 2 && (
              <div className="px-3 py-2 border-b border-[#1e334a] flex items-center gap-2 bg-[#051424]/70">
                <Search className="w-3.5 h-3.5 text-[#7891a8] shrink-0" />
                <input
                  ref={searchInputRef}
                  type="text"
                  value={searchQuery}
                  onChange={(e) => {
                    setSearchQuery(e.target.value);
                    setHighlightedIndex(0);
                  }}
                  onKeyDown={handleKeyDown}
                  placeholder="Type to filter..."
                  className="w-full bg-transparent text-xs text-[#e6f1fc] placeholder-[#7891a8] outline-none font-mono"
                />
                {searchQuery && (
                  <button
                    type="button"
                    onClick={() => setSearchQuery('')}
                    className="text-[#7891a8] hover:text-[#e6f1fc]"
                  >
                    <X className="w-3 h-3" />
                  </button>
                )}
              </div>
            )}

            {/* Options List */}
            <div className="max-h-60 overflow-y-auto divide-y divide-[#1e334a]/30 py-1" role="listbox">
              {filteredOptions.length === 0 ? (
                <div className="px-3 py-3 text-xs text-[#7891a8] italic text-center">
                  No matching options found
                </div>
              ) : (
                filteredOptions.map((opt, index) => {
                  const isSelected = opt.value === value;
                  const isHighlighted = index === highlightedIndex;

                  return (
                    <div
                      key={opt.value}
                      role="option"
                      aria-selected={isSelected}
                      onClick={() => {
                        onChange(opt.value);
                        setIsOpen(false);
                      }}
                      onMouseEnter={() => setHighlightedIndex(index)}
                      className={`px-3 py-2 text-xs cursor-pointer flex items-center justify-between gap-2.5 transition-colors ${
                        isHighlighted
                          ? 'bg-[#182c42] text-[#00e5ff]'
                          : isSelected
                          ? 'bg-[#112234] text-[#e6f1fc]'
                          : 'text-[#b5c7d8] hover:text-[#e6f1fc]'
                      }`}
                    >
                      <div className="min-w-0 flex-1">
                        <div className="font-medium truncate flex items-center gap-2">
                          {opt.icon && <span className="shrink-0">{opt.icon}</span>}
                          <span>{opt.label}</span>
                          {opt.badge && (
                            <span className="text-[10px] px-1.5 py-0.2 bg-[#00e5ff]/10 text-[#00e5ff] rounded border border-[#00e5ff]/25 font-semibold">
                              {opt.badge}
                            </span>
                          )}
                        </div>
                        {opt.description && (
                          <div className="text-[10px] text-[#7891a8] truncate mt-0.5">
                            {opt.description}
                          </div>
                        )}
                      </div>

                      {isSelected && (
                        <Check className="w-3.5 h-3.5 text-[#00e5ff] shrink-0 ml-2" />
                      )}
                    </div>
                  );
                })
              )}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
};
