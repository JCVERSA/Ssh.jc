// Password authentication for the SSH.JC Control Center.
//
// The console can run root-level installers, so every API route (except
// /api/health and /api/auth/login) requires a session.
//
// Credential sources, in priority order:
//   1. GUI_PASSWORD_HASH — a scrypt hash produced by `npm run set-password`.
//   2. GUI_PASSWORD      — a plaintext password (hashed in memory at boot).
//   3. Neither           — a random password is generated and printed once
//                          to the server log so the operator can sign in.
//
// Passwords are hashed with scrypt (node:crypto) and compared in constant
// time. Sessions are random 256-bit tokens kept in memory; the cookie is
// HttpOnly + SameSite=Lax (+ Secure when the request arrives over HTTPS).

import crypto from 'crypto';
import type { Request, Response, NextFunction } from 'express';

const SCRYPT_KEYLEN = 64;
const SESSION_TTL_MS = 12 * 60 * 60 * 1000; // 12 hours
const COOKIE_NAME = 'sshjc_session';

export function hashPassword(password: string): string {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(password, salt, SCRYPT_KEYLEN);
  return `scrypt$${salt.toString('hex')}$${hash.toString('hex')}`;
}

export function verifyPassword(password: string, stored: string): boolean {
  try {
    const [scheme, saltHex, hashHex] = stored.split('$');
    if (scheme !== 'scrypt' || !saltHex || !hashHex) return false;
    const expected = Buffer.from(hashHex, 'hex');
    const actual = crypto.scryptSync(password, Buffer.from(saltHex, 'hex'), expected.length);
    return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}

// --- Credential bootstrap -------------------------------------------------

let passwordHash: string;
const fromEnv = process.env.GUI_PASSWORD_HASH;
const plainEnv = process.env.GUI_PASSWORD;

if (fromEnv && fromEnv.startsWith('scrypt$')) {
  passwordHash = fromEnv;
} else {
  if (fromEnv) {
    console.warn('[SSH.JC] GUI_PASSWORD_HASH is malformed (expected scrypt$...); ignoring it.');
  }
  if (plainEnv) {
    passwordHash = hashPassword(plainEnv);
  } else {
    const generated = crypto.randomBytes(12).toString('base64url');
    passwordHash = hashPassword(generated);
    console.log('================================================================');
    console.log('[SSH.JC] No GUI_PASSWORD / GUI_PASSWORD_HASH configured.');
    console.log(`[SSH.JC] Generated console password for this run: ${generated}`);
    console.log('[SSH.JC] Set GUI_PASSWORD (or GUI_PASSWORD_HASH via');
    console.log('[SSH.JC] `npm run set-password`) to choose your own.');
    console.log('================================================================');
  }
}

// --- Sessions --------------------------------------------------------------

const sessions = new Map<string, { createdAt: number; expiresAt: number }>();

export function createSession(): string {
  const token = crypto.randomBytes(32).toString('hex');
  const now = Date.now();
  sessions.set(token, { createdAt: now, expiresAt: now + SESSION_TTL_MS });
  return token;
}

function parseCookies(req: Request): Record<string, string> {
  const header = req.headers.cookie;
  const out: Record<string, string> = {};
  if (!header) return out;
  for (const part of header.split(';')) {
    const idx = part.indexOf('=');
    if (idx > 0) out[part.slice(0, idx).trim()] = decodeURIComponent(part.slice(idx + 1).trim());
  }
  return out;
}

export function isAuthenticated(req: Request): boolean {
  const token = parseCookies(req)[COOKIE_NAME];
  if (!token) return false;
  const session = sessions.get(token);
  if (!session) return false;
  if (Date.now() > session.expiresAt) {
    sessions.delete(token);
    return false;
  }
  return true;
}

export function destroySession(req: Request): void {
  const token = parseCookies(req)[COOKIE_NAME];
  if (token) sessions.delete(token);
}

export function sessionCookie(token: string, secure: boolean): string {
  const parts = [
    `${COOKIE_NAME}=${encodeURIComponent(token)}`,
    'HttpOnly',
    'Path=/',
    'SameSite=Lax',
    `Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`,
  ];
  if (secure) parts.push('Secure');
  return parts.join('; ');
}

export function clearedCookie(): string {
  return `${COOKIE_NAME}=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0`;
}

function isSecureRequest(req: Request): boolean {
  return req.secure || req.headers['x-forwarded-proto'] === 'https';
}

// --- Login rate limiting (per source IP) ------------------------------------

const loginAttempts = new Map<string, { count: number; blockedUntil: number }>();
const MAX_ATTEMPTS = 8;
const BLOCK_MS = 5 * 60 * 1000;

function loginBlocked(ip: string): boolean {
  const entry = loginAttempts.get(ip);
  return Boolean(entry && entry.blockedUntil > Date.now());
}

function recordFailedLogin(ip: string): void {
  const entry = loginAttempts.get(ip) || { count: 0, blockedUntil: 0 };
  entry.count += 1;
  if (entry.count >= MAX_ATTEMPTS) {
    entry.blockedUntil = Date.now() + BLOCK_MS;
    entry.count = 0;
  }
  loginAttempts.set(ip, entry);
}

// --- Route handlers ----------------------------------------------------------

export function handleLogin(req: Request, res: Response): void {
  const ip = req.ip || 'unknown';
  if (loginBlocked(ip)) {
    res.status(429).json({ success: false, error: 'Too many failed attempts. Try again in a few minutes.' });
    return;
  }
  const password = typeof req.body?.password === 'string' ? req.body.password : '';
  if (!password || !verifyPassword(password, passwordHash)) {
    recordFailedLogin(ip);
    res.status(401).json({ success: false, error: 'Invalid password.' });
    return;
  }
  loginAttempts.delete(ip);
  const token = createSession();
  res.setHeader('Set-Cookie', sessionCookie(token, isSecureRequest(req)));
  res.json({ success: true, data: { authenticated: true } });
}

export function handleLogout(req: Request, res: Response): void {
  destroySession(req);
  res.setHeader('Set-Cookie', clearedCookie());
  res.json({ success: true, data: { authenticated: false } });
}

export function handleSession(req: Request, res: Response): void {
  res.json({ success: true, data: { authenticated: isAuthenticated(req) } });
}

export function requireAuth(req: Request, res: Response, next: NextFunction): void {
  if (req.path === '/health' || req.path.startsWith('/auth/')) {
    next();
    return;
  }
  if (!isAuthenticated(req)) {
    res.status(401).json({ success: false, error: 'Authentication required. Please sign in.' });
    return;
  }
  next();
}
