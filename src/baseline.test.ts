import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { ERROR_CODES, errorCodeHttpStatus } from './errors.js';
import { EMPLOYEE_ROLES } from './roles.js';
import { PERMISSIONS, PERMISSION_KEYS, ROLE_DEFAULT_PERMISSIONS } from './permissions.js';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const baselinePath = resolve(
  packageRoot,
  process.env['ECOFIN_BASELINE_SQL'] ??
    '../EcoFin-API/supabase/migrations/20261002000000_v1_baseline.sql',
);

function loadBaseline(): string {
  if (!existsSync(baselinePath)) {
    throw new Error(
      `Baseline SQL not found at ${baselinePath}. Set ECOFIN_BASELINE_SQL to its path, or place ` +
        'EcoFin-API next to this package (default: ../EcoFin-API/supabase/migrations/20261002000000_v1_baseline.sql).',
    );
  }
  return readFileSync(baselinePath, 'utf8');
}

const sql = loadBaseline();

function between(text: string, startMarker: string, endMarker: string, from = 0): string {
  const s = text.indexOf(startMarker, from);
  if (s < 0) throw new Error(`marker not found: ${startMarker}`);
  const e = text.indexOf(endMarker, s);
  if (e < 0) throw new Error(`marker not found: ${endMarker}`);
  return text.slice(s, e + endMarker.length);
}

describe('baseline parity: roles', () => {
  it('employee roles equal the employee_role enum', () => {
    const body = between(sql, 'CREATE TYPE public.employee_role', ');');
    const values = [...body.matchAll(/'([A-Z_]+)'/g)].map((m) => m[1] as string);
    expect([...EMPLOYEE_ROLES]).toEqual(values);
  });
});

describe('baseline parity: permissions', () => {
  const block = between(
    sql,
    'INSERT INTO public.permissions (key, module, description) VALUES',
    "'legal.manage',             'legal',      'Open and update legal cases');",
  );
  const rows = [...block.matchAll(/\(\s*'([^']+)',\s*'([^']+)',\s*'((?:[^']|'')*)'\)/g)].map(
    (m) => ({
      key: m[1] as string,
      module: m[2] as string,
      description: (m[3] ?? '').replace(/''/g, "'"),
    }),
  );

  it('has 61 keys in the seed and in the package', () => {
    expect(rows).toHaveLength(61);
    expect(PERMISSION_KEYS).toHaveLength(61);
    expect(new Set(PERMISSION_KEYS).size).toBe(61);
  });

  it('keys, modules and descriptions match the seed exactly (same order)', () => {
    expect(PERMISSIONS.map((p) => ({ ...p }))).toEqual(rows);
    expect([...PERMISSION_KEYS]).toEqual(rows.map((r) => r.key));
  });

  it('role defaults match the seeded role_permissions', () => {
    const allKeys = rows.map((r) => r.key);
    const expected: Record<string, string[]> = {};

    // OWNER has no rows: app.has_permission grants every key.
    expected['OWNER'] = allKeys;

    // BRANCH_MANAGER: every key except the NOT IN list.
    const notIn = between(sql, 'WHERE key NOT IN (', ');');
    const excluded = new Set([...notIn.matchAll(/'([^']+)'/g)].map((m) => m[1] as string));
    expected['BRANCH_MANAGER'] = allKeys.filter((k) => !excluded.has(k));

    // Other roles: the VALUES list.
    const values = between(sql, 'FROM (VALUES', ') AS r(role, key)');
    for (const m of values.matchAll(/\('([A-Z_]+)',\s*'([^']+)'\)/g)) {
      (expected[m[1] as string] ??= []).push(m[2] as string);
    }

    expect(Object.keys(ROLE_DEFAULT_PERMISSIONS).sort()).toEqual([...EMPLOYEE_ROLES].sort());
    for (const role of EMPLOYEE_ROLES) {
      expect([...ROLE_DEFAULT_PERMISSIONS[role]].sort(), role).toEqual(
        [...(expected[role] ?? [])].sort(),
      );
    }
    expect(excluded.size).toBe(10);
  });
});

describe('baseline parity: error codes', () => {
  it('every RAISE EXCEPTION code in the baseline is in the enum', () => {
    const codes = new Set(
      [...sql.matchAll(/RAISE EXCEPTION '([A-Z][A-Z_]+)/g)].map((m) => m[1] as string),
    );
    expect(codes.size).toBeGreaterThanOrEqual(26);
    const missing = [...codes].filter((c) => !(ERROR_CODES as string[]).includes(c));
    expect(missing).toEqual([]);
  });

  it('every code has a valid HTTP error status', () => {
    for (const code of ERROR_CODES) {
      const status = errorCodeHttpStatus[code];
      expect(status).toBeGreaterThanOrEqual(400);
      expect(status).toBeLessThan(600);
    }
  });
});
