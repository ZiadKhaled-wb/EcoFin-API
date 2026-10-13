// O03: the pairing code and the device token as the API makes them.
import { createHash } from 'node:crypto';
import { describe, it, expect } from 'vitest';
import { PAIRING_CODE_ALPHABET, isPairingCode } from '@ziadkhaled-wb/contracts';
import {
  isDeviceToken,
  newDeviceToken,
  newPairingCode,
  pairingExpiry,
  sha256Hex,
} from './deviceSecrets';

describe('pairing code', () => {
  it('is 8 characters of the 31-letter alphabet: no 0, O, 1, I or L', () => {
    expect(PAIRING_CODE_ALPHABET).toBe('ABCDEFGHJKMNPQRSTUVWXYZ23456789');
    const seen = new Set<string>();
    for (let i = 0; i < 500; i += 1) {
      const code = newPairingCode();
      expect(code).toHaveLength(8);
      expect(isPairingCode(code)).toBe(true);
      expect(code).not.toMatch(/[01OIL]/);
      for (const c of code) seen.add(c);
    }
    // 4000 draws: every one of the 31 characters turns up.
    expect(seen.size).toBe(31);
  });

  it('two codes differ', () => {
    expect(newPairingCode()).not.toBe(newPairingCode());
  });

  it('expires 15 minutes after it was made', () => {
    const now = new Date('2026-10-13T09:00:00.000Z');
    expect(pairingExpiry(now).toISOString()).toBe('2026-10-13T09:15:00.000Z');
  });
});

describe('device token', () => {
  it('is 32 random bytes as base64url', () => {
    const token = newDeviceToken();
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(Buffer.from(token, 'base64url')).toHaveLength(32);
    expect(isDeviceToken(token)).toBe(true);
    expect(newDeviceToken()).not.toBe(token);
  });

  it('anything else is not a device token', () => {
    for (const bad of [undefined, '', 'short', 'a'.repeat(44), `${'a'.repeat(42)}=`, ['a']]) {
      expect(isDeviceToken(bad)).toBe(false);
    }
  });
});

describe('sha256Hex', () => {
  it('is the SHA-256 of the text as 64 lower-case hex characters, and never the text', () => {
    const hash = sha256Hex('ABCDEFGH');
    expect(hash).toBe(createHash('sha256').update('ABCDEFGH').digest('hex'));
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
    expect(hash).not.toContain('ABCDEFGH');
  });
});
