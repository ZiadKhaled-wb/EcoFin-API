import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { getOwnerDashboard } from './dashboard.service';

const BR = 'a0100000-0000-4000-8000-000000000002';
const ts = '2026-10-21T10:00:00.000Z';
const tiles = {
  sales_today: {
    count: 1,
    total: '300.00',
    paid_by_method: { cash: '300.00', bank_transfer: '0.00', store_credit: '0.00' },
    on_contract: '0.00',
  },
  collections_today: null,
  cash: null,
  open_shifts: { count: 0, oldest_opened_at: null, from_earlier_days: 0 },
  overdue: null,
  low_stock: null,
  eta: null,
  unclosed_days: null,
  approvals: { discount: 1, purchase: null, credit: null, total: 1 },
};
const dashboard = { business_date: '2026-10-21', branch_id: null, generated_at: ts, tiles };

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'OWNER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('D01 owner dashboard service', () => {
  it('asks for all branches without a branch argument', async () => {
    const { db, ctx } = setup();
    db.queue({ data: dashboard, error: null });
    const out = await getOwnerDashboard(ctx, {});
    expect(db.rpc).toHaveBeenCalledWith('get_owner_dashboard', {});
    expect(out.tiles.sales_today?.total).toBe('300.00');
    expect(out.tiles.cash).toBeNull();
  });

  it('passes the branch and returns the money as the server wrote it', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { ...dashboard, branch_id: BR }, error: null });
    const out = await getOwnerDashboard(ctx, { branch_id: BR });
    expect(db.rpc).toHaveBeenCalledWith('get_owner_dashboard', { p_branch_id: BR });
    expect(out.branch_id).toBe(BR);
  });

  it('maps the branch errors to their codes', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'BRANCH_NOT_FOUND', code: 'P0001' } });
    await expect(getOwnerDashboard(ctx, { branch_id: BR })).rejects.toMatchObject({
      code: 'BRANCH_NOT_FOUND',
      statusCode: 404,
    });
    db.queue({ data: null, error: { message: `BRANCH_DENIED: ${BR}`, code: '42501' } });
    await expect(getOwnerDashboard(ctx, { branch_id: BR })).rejects.toMatchObject({
      code: 'BRANCH_DENIED',
      statusCode: 403,
    });
  });

  it('refuses an answer that does not match the contract', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: {
        ...dashboard,
        tiles: { ...tiles, sales_today: { ...tiles.sales_today, total: 300 } },
      },
      error: null,
    });
    await expect(getOwnerDashboard(ctx, {})).rejects.toThrow();
  });

  it('hides a database failure behind a generic error', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'relation "x" does not exist', code: '42P01' } });
    await expect(getOwnerDashboard(ctx, {})).rejects.toMatchObject({ statusCode: 500 });
  });
});
