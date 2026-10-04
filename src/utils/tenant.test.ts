import { describe, it, expect, beforeEach } from 'vitest';
import { createSupabaseMock, type SupabaseMock } from '../test/supabase-mock';
import type { DbClient } from './supabase';
import { AppError } from './errors';
import {
  SAME_ORG_TABLES,
  assertOwnPath,
  assertSameOrg,
  tenantFilePath,
  type SameOrgTable,
} from './tenant';

const ORG = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const OTHER_ORG = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const P1 = '11111111-1111-4111-8111-111111111111';
const P2 = '22222222-2222-4222-8222-222222222222';

async function codeOf(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (err) {
    return err instanceof AppError ? err.code : `not an AppError: ${String(err)}`;
  }
  return 'resolved';
}

function codeOfSync(fn: () => unknown): string {
  try {
    fn();
  } catch (err) {
    return err instanceof AppError ? err.code : `not an AppError: ${String(err)}`;
  }
  return 'returned';
}

describe('assertSameOrg', () => {
  let db: SupabaseMock;
  let ctx: { db: DbClient; orgId: string };

  beforeEach(() => {
    db = createSupabaseMock();
    ctx = { db: db as unknown as DbClient, orgId: ORG };
  });

  it('resolves when every id is visible in the caller shop, filtering on the org too', async () => {
    db.queue({ data: [{ id: P1 }, { id: P2 }], error: null });
    await expect(assertSameOrg(ctx, 'products', [P1, P2, P1])).resolves.toBeUndefined();
    expect(db.from).toHaveBeenCalledWith('products');
    expect(db.eq).toHaveBeenCalledWith('organization_id', ORG);
    expect(db.in).toHaveBeenCalledWith('id', [P1, P2]);
  });

  it('an id the DB does not return (another shop, RLS) -> 404 NOT_FOUND', async () => {
    db.queue({ data: [{ id: P1 }], error: null });
    expect(await codeOf(assertSameOrg(ctx, 'customers', [P1, P2]))).toBe('NOT_FOUND');
  });

  it('a non-uuid id -> 404 without a DB call', async () => {
    expect(await codeOf(assertSameOrg(ctx, 'products', ['1 OR 1=1']))).toBe('NOT_FOUND');
    expect(db.from).not.toHaveBeenCalled();
  });

  it('no ids -> nothing to check, no DB call', async () => {
    await expect(assertSameOrg(ctx, 'products', [])).resolves.toBeUndefined();
    expect(db.from).not.toHaveBeenCalled();
  });

  it('a table outside the allow-list is refused before any query', async () => {
    await expect(assertSameOrg(ctx, 'audit_log' as SameOrgTable, [P1])).rejects.toThrow(
      /not in SAME_ORG_TABLES/,
    );
    await expect(
      assertSameOrg(ctx, 'products; drop table x' as SameOrgTable, [P1]),
    ).rejects.toThrow(/not in SAME_ORG_TABLES/);
    expect(db.from).not.toHaveBeenCalled();
  });

  it('a DB error is a 500, not a raw message', async () => {
    db.queue({ data: null, error: { message: 'relation does not exist', code: '42P01' } });
    expect(await codeOf(assertSameOrg(ctx, 'products', [P1]))).toBe('INTERNAL');
  });

  it('every allow-listed table is unique', () => {
    expect(new Set(SAME_ORG_TABLES).size).toBe(SAME_ORG_TABLES.length);
  });
});

describe('tenantFilePath', () => {
  const ctx = { orgId: ORG };

  it('always starts with the caller org id', () => {
    expect(tenantFilePath(ctx, 'invoices', 'INV-1.pdf')).toBe(`${ORG}/invoices/INV-1.pdf`);
    expect(tenantFilePath(ctx, 'invoices/2026', 'a.pdf')).toBe(`${ORG}/invoices/2026/a.pdf`);
  });

  it.each([
    ['..', ['..', 'x.pdf']],
    ['a nested ..', ['invoices/../../other', 'x.pdf']],
    ['.', ['.', 'x.pdf']],
    ['an absolute path', ['/etc/passwd']],
    ['an empty part', ['invoices', '']],
    ['a double slash', ['invoices//x.pdf']],
    ['a backslash', ['..\\x.pdf']],
    ['a NUL', ['x\u0000.pdf']],
    ['no parts', []],
  ])('rejects %s -> 400 VALIDATION_FAILED', (_name, parts) => {
    expect(codeOfSync(() => tenantFilePath(ctx, ...parts))).toBe('VALIDATION_FAILED');
  });

  it("a caller can't build another org's prefix (it is always nested under its own)", () => {
    expect(tenantFilePath(ctx, OTHER_ORG, 'x.pdf')).toBe(`${ORG}/${OTHER_ORG}/x.pdf`);
  });
});

describe('assertOwnPath', () => {
  const ctx = { orgId: ORG };

  it('returns a path under the caller org', () => {
    expect(assertOwnPath(ctx, `${ORG}/invoices/a.pdf`)).toBe(`${ORG}/invoices/a.pdf`);
  });

  it.each([
    ["another org's prefix", `${OTHER_ORG}/invoices/a.pdf`],
    ['an absolute path', `/${ORG}/a.pdf`],
    ['the org folder itself', ORG],
    ['.. after the prefix', `${ORG}/../${OTHER_ORG}/a.pdf`],
    ['an empty part', `${ORG}//a.pdf`],
    ['the org id only as a prefix of the first part', `${ORG}x/a.pdf`],
  ])('refuses %s -> 404 NOT_FOUND', (_name, path) => {
    expect(codeOfSync(() => assertOwnPath(ctx, path))).toBe('NOT_FOUND');
  });
});
