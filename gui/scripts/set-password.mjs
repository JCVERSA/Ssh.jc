#!/usr/bin/env node
// Generate a GUI_PASSWORD_HASH (scrypt) for the SSH.JC Control Center.
// Usage: npm run set-password -- 'your-password'
// Then put the printed line in your environment (.env) and restart.

import crypto from 'crypto';

const password = process.argv[2];
if (!password) {
  console.error("Usage: npm run set-password -- 'your-password'");
  process.exit(1);
}

const salt = crypto.randomBytes(16);
const hash = crypto.scryptSync(password, salt, 64);
console.log(`GUI_PASSWORD_HASH=scrypt$${salt.toString('hex')}$${hash.toString('hex')}`);
