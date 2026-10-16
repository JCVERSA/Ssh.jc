import React, { useState, useEffect, useRef } from 'react';
import { Search, Copy, Check, RotateCw, Terminal, FileCode } from 'lucide-react';
import { LogEntry } from '../types';
import { fetchLogs } from '../api';
import { Button } from './ui/Button';
import { Checkbox } from './ui/Checkbox';
import { GlassCard } from './ui/GlassCard';

interface LogStreamViewerProps {
  initialLogs?: LogEntry[];
}

export const LogStreamViewer: React.FC<LogStreamViewerProps> = ({ initialLogs = [] }) => {
  const [logs, setLogs] = useState<LogEntry[]>(initialLogs);
  const [searchTerm, setSearchTerm] = useState('');
  const [levelFilter, setLevelFilter] = useState<'all' | 'info' | 'ok' | 'warn' | 'error'>('all');
  const [autoScroll, setAutoScroll] = useState(true);
  const [copied, setCopied] = useState(false);
  const [isRefreshing, setIsRefreshing] = useState(false);

  const logEndRef = useRef<HTMLDivElement>(null);

  const loadLogs = async () => {
    setIsRefreshing(true);
    try {
      const freshLogs = await fetchLogs(200);
      setLogs(freshLogs);
    } catch {
      // ignore transient failures
    } finally {
      setIsRefreshing(false);
    }
  };

  useEffect(() => {
    loadLogs();
    const interval = setInterval(loadLogs, 4000);
    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    if (autoScroll && logEndRef.current) {
      logEndRef.current.scrollIntoView({ behavior: 'smooth' });
    }
  }, [logs, autoScroll]);

  const filteredLogs = logs.filter((log) => {
    if (levelFilter !== 'all' && log.level !== levelFilter) return false;
    if (searchTerm && !log.message.toLowerCase().includes(searchTerm.toLowerCase())) return false;
    return true;
  });

  const handleCopyLogs = () => {
    const text = filteredLogs
      .map((l) => `[${l.timestamp}] [${l.level.toUpperCase()}] ${l.message}`)
      .join('\n');
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 pb-2 border-b border-[#1e334a]">
        <div>
          <h1 className="text-xl font-semibold tracking-tight text-[#e6f1fc] flex items-center gap-2">
            <FileCode className="w-5 h-5 text-[#00e5ff]" />
            <span>System Log Telemetry</span>
          </h1>
          <p className="text-xs text-[#b5c7d8] mt-0.5">
            Streaming logs aggregated from Install.sh runs, sshd daemons, and background tunnel processes.
          </p>
        </div>

        <div className="flex items-center gap-2.5">
          <Button
            variant="secondary"
            size="sm"
            onClick={loadLogs}
            disabled={isRefreshing}
            isLoading={isRefreshing}
            leftIcon={<RotateCw className="w-3.5 h-3.5 text-[#00e5ff]" />}
          >
            Poll Now
          </Button>
          <Button
            variant="secondary"
            size="sm"
            onClick={handleCopyLogs}
            leftIcon={copied ? <Check className="w-3.5 h-3.5 text-[#10b981]" /> : <Copy className="w-3.5 h-3.5 text-[#00e5ff]" />}
          >
            {copied ? 'Copied' : 'Export Logs'}
          </Button>
        </div>
      </div>

      {/* Terminal Container */}
      <div className="bg-[#030d18] border border-[#1e334a] rounded overflow-hidden shadow-2xl">
        {/* Terminal Utility Toolbar */}
        <div className="bg-[#071320] px-4 py-2.5 border-b border-[#1e334a] flex flex-wrap items-center justify-between gap-3 text-xs">
          <div className="flex items-center gap-2 flex-1 min-w-[200px] max-w-md">
            <Search className="w-3.5 h-3.5 text-[#7891a8]" />
            <input
              type="text"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              placeholder="Filter log messages..."
              className="w-full bg-[#030d18] border border-[#1e334a] focus:border-[#00e5ff] rounded px-3 py-1.5 text-xs font-mono text-[#e6f1fc] outline-none"
            />
          </div>

          <div className="flex items-center gap-2 font-mono">
            <span className="text-[#7891a8] text-[11px]">Level:</span>
            {(['all', 'info', 'ok', 'warn', 'error'] as const).map((lvl) => (
              <button
                key={lvl}
                onClick={() => setLevelFilter(lvl)}
                className={`px-2 py-0.5 rounded text-[11px] uppercase transition-colors cursor-pointer ${
                  levelFilter === lvl
                    ? 'bg-[#00e5ff] text-[#030d18] font-semibold'
                    : 'bg-[#112234] text-[#b5c7d8] hover:text-[#e6f1fc]'
                }`}
              >
                {lvl}
              </button>
            ))}

            <div className="h-4 w-px bg-[#1e334a] mx-1" />

            <Checkbox
              checked={autoScroll}
              onChange={setAutoScroll}
              label="Auto-Scroll"
            />
          </div>
        </div>

        {/* Log Lines Display */}
        <div className="p-4 font-mono text-xs max-h-[500px] min-h-[300px] overflow-y-auto space-y-1.5 select-text">
          {filteredLogs.length === 0 ? (
            <div className="text-[#7891a8] italic py-8 text-center">
              No matching log records found in host telemetry buffer.
            </div>
          ) : (
            filteredLogs.map((log) => (
              <div key={log.id} className="flex items-start gap-2.5 leading-relaxed hover:bg-[#071320]/60 px-1 py-0.5 rounded">
                <span className="text-[#475569] text-[10px] shrink-0">
                  {new Date(log.timestamp).toLocaleTimeString()}
                </span>
                <span
                  className={`shrink-0 text-[10px] px-1.5 py-0.2 rounded font-semibold uppercase ${
                    log.level === 'ok'
                      ? 'text-[#10b981] bg-[#10b981]/15 border border-[#10b981]/30'
                      : log.level === 'warn'
                      ? 'text-[#f59e0b] bg-[#f59e0b]/15 border border-[#f59e0b]/30'
                      : log.level === 'error'
                      ? 'text-[#ef4444] bg-[#ef4444]/15 border border-[#ef4444]/30'
                      : 'text-[#00e5ff] bg-[#00e5ff]/15 border border-[#00e5ff]/30'
                  }`}
                >
                  {log.level}
                </span>
                <span className="text-[#e6f1fc] break-all">{log.message}</span>
              </div>
            ))
          )}
          <div ref={logEndRef} />
        </div>
      </div>
    </div>
  );
};
