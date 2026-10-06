import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import { listBranches } from './branches.service';
describe('O01 branch service', () => {
  it('filters active unarchived branches by caller scope and sorts main first', async () => {
    const db = createSupabaseMock();
    const id = 'a0100000-0000-4000-8000-000000000001';
    db.queue({ data: [{ id, code: 'MAIN', name: 'Main', is_main: true }], error: null });
    const ctx: RequestContext = {
      userId: 'u',
      employeeId: 'e',
      orgId: 'org',
      role: 'CASHIER',
      defaultBranchId: id,
      branchIds: [id],
      mustChangePassword: false,
      db: db as unknown as DbClient,
    };
    expect(await listBranches(ctx)).toEqual([{ id, code: 'MAIN', name: 'Main', is_main: true }]);
    expect(db.eq).toHaveBeenCalledWith('organization_id', 'org');
    expect(db.eq).toHaveBeenCalledWith('is_active', true);
    expect(db.is).toHaveBeenCalledWith('archived_at', null);
    expect(db.in).toHaveBeenCalledWith('id', [id]);
    expect(db.order).toHaveBeenCalledWith('is_main', { ascending: false });
  });
  it.each([
    ['BRANCH_CODE_INVALID', 400],
    ['BRANCH_CODE_TAKEN', 409],
    ['BRANCH_NOT_FOUND', 404],
    ['BRANCH_INACTIVE', 403],
    ['MAIN_BRANCH_REQUIRED', 409],
    ['VAULT_INVALID', 400],
    ['BRANCH_DEACTIVATE_NEEDS_CONFIRM', 409],
  ] as const)('maps %s', (code, status) => {
    expect(mapDbError({ message: code + ': private detail' })).toMatchObject({
      code,
      statusCode: status,
    });
  });
  it('exposes only validated warning counts, including decimal cash', () => {
    const detail = { open_shifts: 1, stock_units: 2, cash_balance: '30.25' };
    expect(
      mapDbError({ message: 'BRANCH_DEACTIVATE_NEEDS_CONFIRM', details: JSON.stringify(detail) })
        ?.details,
    ).toEqual(detail);
    expect(
      mapDbError({
        message: 'BRANCH_DEACTIVATE_NEEDS_CONFIRM',
        details: JSON.stringify({ ...detail, private: 'secret' }),
      })?.details,
    ).toBeUndefined();
  });
});
