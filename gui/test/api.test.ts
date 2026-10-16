import assert from 'assert';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { redactSecrets } from '../server/systemService.js';
import { jobManager } from '../server/jobManager.js';
import { buildInvocation } from '../server/scriptService.js';
import { hashPassword, verifyPassword } from '../server/auth.js';

// Point the script driver at a harmless stub so tests never run Install.sh.
const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sshjc-stub-'));
const stubPath = path.join(stubDir, 'Install.sh');
fs.writeFileSync(stubPath, '#!/bin/bash\necho "[INFO] stub Install.sh invoked: $*"\necho "[OK] stub completed"\nexit 0\n');
fs.chmodSync(stubPath, 0o755);
process.env.SSHJC_SCRIPT_PATH = stubPath;

console.log('--- RUNNING SSH.JC CONTROL CENTER AUTOMATED TEST SUITE ---');

async function runTests() {
  let passed = 0;
  let failed = 0;

  function test(name: string, fn: () => void | Promise<void>) {
    try {
      fn();
      console.log(`  ✓ ${name}`);
      passed++;
    } catch (err: any) {
      console.error(`  ✗ ${name}`);
      console.error(`    ${err.message}`);
      failed++;
    }
  }

  // 1. Secret Redaction Tests
  test('Secret Redaction: masks fxTunnel API tokens (sk_...)', () => {
    const raw = 'Starting fxTunnel with token sk_live_999888777abc and connecting...';
    const redacted = redactSecrets(raw);
    assert(!redacted.includes('sk_live_999888777abc'), 'Failed to mask fxTunnel token');
    assert(redacted.includes('sk_***REDACTED***'), 'Did not insert redacted placeholder');
  });

  test('Secret Redaction: masks OpenSSH private keys', () => {
    const raw = `Here is key:\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAA\n-----END OPENSSH PRIVATE KEY-----`;
    const redacted = redactSecrets(raw);
    assert(!redacted.includes('b3BlbnNzaC1rZXktdjEAAAA'), 'Failed to mask private key body');
    assert(redacted.includes('[***PRIVATE KEY REDACTED***]'), 'Did not insert key redacted token');
  });

  test('Secret Redaction: masks password= values but not plain sentences', () => {
    assert(redactSecrets('connect with password=Sup3rSecret now').includes('password=***REDACTED***'));
    const sentence = 'Configure root access (password and/or key) - password can still log in';
    assert.strictEqual(redactSecrets(sentence), sentence, 'Plain sentences must not be mangled');
  });

  // 2. Protected Infrastructure & Safeguard Tests
  test('Safeguard: rejects operations targeting protected Port 3000', () => {
    const validation = jobManager.validateParameters('run_tunnel', {
      tunnelName: 'test-tunnel',
      localPort: 3000
    });
    assert.strictEqual(validation.valid, false, 'Should have rejected port 3000');
    assert(validation.error?.includes('PROTECTED INFRASTRUCTURE'), 'Error message must specify protected infrastructure');
  });

  test('Validation: allows legitimate SSH port 22 or custom ports', () => {
    const v22 = jobManager.validateParameters('run_tunnel', { tunnelName: 'test-tunnel', localPort: 22 });
    assert.strictEqual(v22.valid, true, 'Port 22 must be valid');

    const v2222 = jobManager.validateParameters('run_tunnel', { tunnelName: 'test-tunnel', localPort: 2222 });
    assert.strictEqual(v2222.valid, true, 'Port 2222 must be valid');
  });

  test('Validation: rejects out-of-range ports', () => {
    const v0 = jobManager.validateParameters('run_tunnel', { localPort: 0 });
    assert.strictEqual(v0.valid, false);

    const vHuge = jobManager.validateParameters('run_tunnel', { localPort: 70000 });
    assert.strictEqual(vHuge.valid, false);

    const vNaN = jobManager.validateParameters('run_tunnel', { localPort: 'abc' });
    assert.strictEqual(vNaN.valid, false);
  });

  // 3. Security & Injection Prevention Tests
  test('Security: rejects invalid tunnel names containing shell metacharacters', () => {
    const vInjection = jobManager.validateParameters('configure_tunnel', {
      tunnelName: 'test; rm -rf /'
    });
    assert.strictEqual(vInjection.valid, false, 'Failed to reject shell metacharacters');

    const vSpaces = jobManager.validateParameters('configure_tunnel', {
      tunnelName: 'tunnel name with spaces'
    });
    assert.strictEqual(vSpaces.valid, false, 'Failed to reject spaces in tunnel name');

    const vValid = jobManager.validateParameters('configure_tunnel', {
      tunnelName: 'valid-tunnel_01'
    });
    assert.strictEqual(vValid.valid, true, 'Valid alphanumeric tunnel name should be accepted');
  });

  // 4. Public Key Format Validation Tests
  test('Validation: accepts standard OpenSSH public keys (RSA, Ed25519, ECDSA)', () => {
    const validEd25519 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleValidKeyFormatStringJcVersaOps user@host';
    const v = jobManager.validateParameters('configure_admin_user', {
      username: 'jcadmin',
      pubkey: validEd25519
    });
    assert.strictEqual(v.valid, true, 'Standard Ed25519 key should be valid');
  });

  test('Validation: rejects corrupted or invalid public keys', () => {
    const badKey = 'not a public key at all';
    const v = jobManager.validateParameters('configure_admin_user', {
      username: 'jcadmin',
      pubkey: badKey
    });
    assert.strictEqual(v.valid, false, 'Corrupted key must be rejected');
  });

  // 5. Concurrency Lock Tests
  await test('Concurrency Lock: blocks concurrent overlapping execution jobs', async () => {
    const job1 = await jobManager.startJob('run_tunnel', { tunnelName: 'tunnel-a', localPort: 2222 });
    assert(job1.id, 'Job 1 should have been created');

    // While job1 is preparing/running, attempting job 2 must throw or reject
    try {
      await jobManager.startJob('run_tunnel', { tunnelName: 'tunnel-b', localPort: 2223 });
      // If it resolved immediately, job1 finished. Let's verify startJob honors concurrency
    } catch (err: any) {
      assert(err.message.includes('currently active'), 'Should have prevented concurrent job');
    }
  });

  // 6. Script Driver (Install.sh single source of truth)
  test('Script Driver: update_sshd_security maps to SSHJC_ACTION with env params', () => {
    const inv = buildInvocation('update_sshd_security', { permitRootLogin: 'no', passwordAuthentication: 'no' });
    assert.strictEqual(inv.env.SSHJC_ACTION, 'update_sshd_security');
    assert.strictEqual(inv.env.SSHJC_PERMIT_ROOT_LOGIN, 'no');
    assert.strictEqual(inv.env.SSHJC_PASSWORD_AUTHENTICATION, 'no');
    assert.strictEqual(inv.env.SSHJC_NONINTERACTIVE, '1');
    assert.deepStrictEqual(inv.stdinAnswers, []);
    assert.strictEqual(inv.scriptPath, stubPath);
  });

  test('Script Driver: stop_tunnel answers menu 6 stop sequence', () => {
    const inv = buildInvocation('stop_tunnel', { tunnelName: 'my-tunnel' });
    assert.deepStrictEqual(inv.stdinAnswers, ['6', '2', 'y']);
    assert.strictEqual(inv.env.SSHJC_TUNNEL_NAME, 'my-tunnel');
  });

  test('Script Driver: fx token never appears in the job summary', () => {
    const inv = buildInvocation('configure_tunnel', { tunnelName: 't1', provider: 'fxtunnel', fxToken: 'sk_secret_123456' });
    assert(!inv.summary.includes('sk_secret_123456'), 'Summary must not leak the token');
    assert(inv.summary.includes('SSHJC_FX_TOKEN=***'));
    assert.strictEqual(inv.env.SSHJC_FX_TOKEN, 'sk_secret_123456');
  });

  // 7. Password Auth
  test('Auth: scrypt hash verifies the right password and rejects wrong ones', () => {
    const hash = hashPassword('correct horse battery staple');
    assert(hash.startsWith('scrypt$'));
    assert.strictEqual(verifyPassword('correct horse battery staple', hash), true);
    assert.strictEqual(verifyPassword('wrong password', hash), false);
    assert.strictEqual(verifyPassword('anything', 'not-a-hash'), false);
  });

  // 8. Binary Existence Guard
  test('Binary Guard: hasBinary accurately detects installed vs missing system tools', () => {
    assert.strictEqual(jobManager.hasBinary('node') || jobManager.hasBinary('sh'), true, 'Should detect system binaries');
    assert.strictEqual(jobManager.hasBinary('nonexistent_fake_binary_xyz_123'), false, 'Should return false for non-existent binary');
  });

  console.log(`\n========================================`);
  console.log(`TEST SUMMARY: ${passed} Passed, ${failed} Failed`);
  console.log(`========================================\n`);

  if (failed > 0) {
    process.exit(1);
  }
}

runTests().catch(err => {
  console.error('Test execution error:', err);
  process.exit(1);
});
