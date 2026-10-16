import React, { useState } from 'react';
import { motion } from 'motion/react';
import { Lock, AlertCircle } from 'lucide-react';
import { Button } from './ui/Button';
import { CyberKeyholeIcon } from './ui/Icons';
import { login } from '../api';

interface LoginProps {
  onSuccess: () => void;
}

export const Login: React.FC<LoginProps> = ({ onSuccess }) => {
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setIsSubmitting(true);
    try {
      await login(password);
      onSuccess();
    } catch (err: any) {
      setError(err.message || 'Invalid password.');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="min-h-screen bg-[#030d18] text-[#e6f1fc] flex items-center justify-center p-4 font-sans antialiased">
      <motion.div
        initial={{ opacity: 0, y: 10 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.25 }}
        className="w-full max-w-sm bg-[#051424]/85 backdrop-blur-xl border border-[#1e334a] rounded-lg shadow-[0_0_40px_rgba(0,229,255,0.08)] p-6"
      >
        <div className="flex flex-col items-center gap-2 mb-6 text-center">
          <CyberKeyholeIcon size={30} className="text-[#00e5ff]" />
          <h1 className="text-base font-semibold tracking-tight">
            <span className="text-[#00e5ff]">SSH.JC</span> Control Center
          </h1>
          <p className="text-xs text-[#7891a8] font-mono">
            This console can run installers on this host.
            Sign in to continue.
          </p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label htmlFor="console-password" className="block text-xs font-mono text-[#b5c7d8] mb-1.5">
              Console password
            </label>
            <div className="relative">
              <Lock className="w-3.5 h-3.5 text-[#7891a8] absolute left-3 top-1/2 -translate-y-1/2" />
              <input
                id="console-password"
                type="password"
                autoComplete="current-password"
                autoFocus
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="w-full pl-9 pr-3 py-2 bg-[#0c1b2c] border border-[#1e334a] focus:border-[#00e5ff] rounded text-sm font-mono text-[#e6f1fc] outline-none"
                placeholder="••••••••••"
              />
            </div>
          </div>

          {error && (
            <div className="p-3 bg-[#ef4444]/15 border border-[#ef4444]/40 rounded text-xs text-[#ffdad6] flex items-center gap-2 font-mono">
              <AlertCircle className="w-4 h-4 text-[#ef4444] shrink-0" />
              <span>{error}</span>
            </div>
          )}

          <Button
            type="submit"
            variant="primary"
            size="lg"
            isLoading={isSubmitting}
            disabled={!password || isSubmitting}
            className="w-full justify-center"
          >
            Sign in
          </Button>
        </form>

        <p className="mt-5 text-[11px] text-[#7891a8] font-mono text-center leading-relaxed">
          Password comes from GUI_PASSWORD / GUI_PASSWORD_HASH,
          or the one-time password printed in the server log.
        </p>
      </motion.div>
    </div>
  );
};
