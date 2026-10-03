// src/utils/password.test.ts
import { describe, it, expect } from 'vitest';
import { generateTempPassword, generateSecureToken, hashToken, verifyTokenHash } from './password';
import { isValidPassword } from './validation';

describe('generateTempPassword', () => {
  it('rejects length below 8', () => {
    expect(() => generateTempPassword(7)).toThrow(/at least 8/);
  });

  it('produces a password that satisfies isValidPassword', () => {
    // The generated password must never be rejected downstream by the
    // app-level validator, otherwise provisioning fails silently.
    for (let i = 0; i < 100; i++) {
      expect(isValidPassword(generateTempPassword())).toBe(true);
    }
  });

  it('honors the requested length', () => {
    expect(generateTempPassword(16)).toHaveLength(16);
    expect(generateTempPassword(8)).toHaveLength(8);
  });

  it('is not deterministic — no two calls in 10k collide', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 10_000; i++) {
      seen.add(generateTempPassword());
    }
    expect(seen.size).toBe(10_000);
  });

  it('includes at least one letter, digit, and symbol', () => {
    for (let i = 0; i < 100; i++) {
      const pw = generateTempPassword();
      expect(pw).toMatch(/[A-Za-z]/);
      expect(pw).toMatch(/\d/);
      expect(pw).toMatch(/[!@#$%^&*]/);
    }
  });
});

describe('generateSecureToken', () => {
  it('produces distinct values', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 10_000; i++) {
      seen.add(generateSecureToken());
    }
    expect(seen.size).toBe(10_000);
  });

  it('respects the requested byte length (approximately)', () => {
    // 32 bytes → 52 base32 chars, 16 bytes → 26 chars.
    expect(generateSecureToken(16).length).toBeGreaterThan(20);
    expect(generateSecureToken(32).length).toBeGreaterThan(45);
  });

  it('uses only base32 alphabet characters', () => {
    expect(generateSecureToken(32)).toMatch(/^[0-9A-HJKMNP-TV-Z]+$/);
  });
});

describe('hashToken + verifyTokenHash', () => {
  it('round-trips the same input', () => {
    const token = generateSecureToken();
    const hash = hashToken(token);
    expect(verifyTokenHash(token, hash)).toBe(true);
  });

  it('rejects a different input', () => {
    const token = generateSecureToken();
    const hash = hashToken(token);
    expect(verifyTokenHash(token + 'x', hash)).toBe(false);
    expect(verifyTokenHash('', hash)).toBe(false);
  });

  it('rejects a hash of different length (no crash on timingSafeEqual)', () => {
    // timingSafeEqual throws on length mismatch. verifyTokenHash must
    // short-circuit before that call.
    expect(verifyTokenHash('anything', 'short')).toBe(false);
  });

  it('hashToken is deterministic', () => {
    const token = 'fixed-value';
    expect(hashToken(token)).toBe(hashToken(token));
  });
});
