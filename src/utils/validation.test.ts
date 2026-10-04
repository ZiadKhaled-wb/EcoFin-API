// src/utils/validation.test.ts
import { describe, it, expect } from 'vitest';
import {
  isValidEmail,
  isValidPassword,
  isValidTenantSlug,
  isValidPermission,
  isValidRole,
  isValidIdempotencyKey,
  VALID_ROLES,
} from './validation';

describe('isValidPassword (NIST-style policy)', () => {
  it('accepts a password at the minimum length', () => {
    expect(isValidPassword('aB3!xY9z')).toBe(true); // 8 chars
  });

  it('rejects passwords below 8 chars', () => {
    expect(isValidPassword('Short1!')).toBe(false);
    expect(isValidPassword('')).toBe(false);
  });

  it('rejects passwords above 128 chars', () => {
    expect(isValidPassword('a'.repeat(129))).toBe(false);
  });

  it('rejects common passwords', () => {
    expect(isValidPassword('password')).toBe(false);
    expect(isValidPassword('PASSWORD123')).toBe(false); // case-insensitive blocklist
    expect(isValidPassword('admin1234')).toBe(false);
  });

  it('accepts non-ASCII passwords — Arabic-first product', () => {
    // The old regex rejected this. NIST-style policy does not.
    expect(isValidPassword('كلمةالمرور!1')).toBe(true);
  });

  it('accepts passwords with leading/trailing whitespace (no trimming)', () => {
    expect(isValidPassword('  aB3!xY9z  ')).toBe(true);
  });

  it('accepts passwords with only letters (no composition rules)', () => {
    expect(isValidPassword('abcdefghij')).toBe(true);
  });

  it('rejects non-strings', () => {
    expect(isValidPassword(null)).toBe(false);
    expect(isValidPassword(undefined)).toBe(false);
    expect(isValidPassword(12345678)).toBe(false);
    expect(isValidPassword({})).toBe(false);
  });
});

describe('isValidTenantSlug', () => {
  it('accepts lowercase alphanumeric with hyphens', () => {
    expect(isValidTenantSlug('testshop')).toBe(true);
    expect(isValidTenantSlug('my-shop-2024')).toBe(true);
    expect(isValidTenantSlug('a1b')).toBe(true);
  });

  it('rejects slugs shorter than 3 or longer than 40', () => {
    expect(isValidTenantSlug('ab')).toBe(false);
    expect(isValidTenantSlug('a'.repeat(41))).toBe(false);
  });

  it('rejects uppercase, spaces, and leading/trailing hyphens', () => {
    expect(isValidTenantSlug('TestShop')).toBe(false);
    expect(isValidTenantSlug('test shop')).toBe(false);
    expect(isValidTenantSlug('-testshop')).toBe(false);
    expect(isValidTenantSlug('testshop-')).toBe(false);
  });

  it('rejects non-strings', () => {
    expect(isValidTenantSlug(null)).toBe(false);
    expect(isValidTenantSlug(42)).toBe(false);
  });
});

describe('isValidPermission', () => {
  it('accepts module-only keys', () => {
    expect(isValidPermission('pos')).toBe(true);
    expect(isValidPermission('crm')).toBe(true);
  });

  it('accepts module.action keys', () => {
    expect(isValidPermission('sales.create')).toBe(true);
    expect(isValidPermission('collections.accept')).toBe(true);
  });

  it('rejects unknown modules', () => {
    expect(isValidPermission('unknown')).toBe(false);
    expect(isValidPermission('unknown.action')).toBe(false);
  });

  it('rejects malformed keys', () => {
    expect(isValidPermission('a.b.c')).toBe(false); // more than one dot
    expect(isValidPermission('')).toBe(false);
    expect(isValidPermission('.action')).toBe(false);
  });

  it('rejects keys over 64 chars', () => {
    expect(isValidPermission(`pos.${'x'.repeat(70)}`)).toBe(false);
  });
});

describe('isValidRole — canonical nine tenant roles only', () => {
  it('accepts every role in VALID_ROLES', () => {
    for (const role of VALID_ROLES) {
      expect(isValidRole(role)).toBe(true);
    }
  });

  it('rejects the retired roles', () => {
    expect(isValidRole('SUPER_ADMIN')).toBe(false); // lives in super_admins table
    expect(isValidRole('MODERATOR')).toBe(false); // removed
    expect(isValidRole('WH_MANAGER')).toBe(false); // renamed to WAREHOUSE_MANAGER
  });

  it('rejects lowercase and unknown values', () => {
    expect(isValidRole('owner')).toBe(false);
    expect(isValidRole('ADMIN')).toBe(false);
    expect(isValidRole(null)).toBe(false);
  });
});

describe('isValidEmail', () => {
  it('accepts standard emails', () => {
    expect(isValidEmail('owner@test.local')).toBe(true);
    expect(isValidEmail('a.b+c@example.co.uk')).toBe(true);
  });

  it('rejects emails over 254 chars', () => {
    const long = 'a'.repeat(250) + '@x.co';
    expect(isValidEmail(long)).toBe(false);
  });

  it('rejects malformed strings', () => {
    expect(isValidEmail('noatsign')).toBe(false);
    expect(isValidEmail('@nodomain')).toBe(false);
    expect(isValidEmail('no@tld.')).toBe(false);
    expect(isValidEmail('')).toBe(false);
  });

  it('is case-insensitive for the check itself', () => {
    expect(isValidEmail('OWNER@TEST.LOCAL')).toBe(true);
  });
});

describe('isValidIdempotencyKey', () => {
  it('accepts UUID v4', () => {
    // Two real v4 UUIDs (version digit '4' in the third group).
    expect(isValidIdempotencyKey('550e8400-e29b-41d4-a716-446655440000')).toBe(true);
    expect(isValidIdempotencyKey('f47ac10b-58cc-4372-a567-0e02b2c3d479')).toBe(true);
  });

  it('rejects UUID v1 (version digit is not 4)', () => {
    // Version digit '1' — time-based UUID.
    expect(isValidIdempotencyKey('2c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d')).toBe(false);
  });

  it('rejects UUID v3 (version digit is not 4)', () => {
    // Version digit '3' — MD5 name-based.
    expect(isValidIdempotencyKey('9125a8dc-52ee-365b-a5aa-81b0b3681cf6')).toBe(false);
  });

  it('accepts ULID', () => {
    expect(isValidIdempotencyKey('01ARZ3NDEKTSV4RRFFQ69G5FAV')).toBe(true);
  });

  it('rejects random strings', () => {
    expect(isValidIdempotencyKey('not-a-key')).toBe(false);
    expect(isValidIdempotencyKey('')).toBe(false);
    expect(isValidIdempotencyKey(null)).toBe(false);
  });
});
