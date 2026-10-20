import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  closeDay,
  getAlerts,
  getDayClose,
  getPreview,
  listDayCloses,
  reopenDay,
} from './dayCloses.service';

const ID = 'a0400000-0000-4000-8000-000000000001';
const BR = 'a0400000-0000-4000-8000-000000000002';
const ts = '2026-10-20T20:00:00.000Z';
const HASH = '0123456789abcdef0123456789abcdef';
const zeros = { cash: '0.00', bank_transfer: '0.00', store_credit: '0.00' };
const ct = { count: 0, total: '0.00' };
const totals = {
  sales: {
    count: 0,
    total: '0.00',
    discount_total: '0.00',
    tax_total: '0.00',
    paid_by_method: zeros,
    on_contract: '0.00',
    voided: ct,
  },
  returns: { count: 0, total: '0.00', refunded_by_method: zeros },
  collections: {
    count: 0,
    total: '0.00',
    principal: '0.00',
    profit: '0.00',
    by_method: zeros,
    in_field: '0.00',
    reversed: ct,
  },
  expenses: { count: 0, total: '0.00', by_category: [], reversed: ct },
  supplier_payments: { ...ct, reversed: ct },
  supplier_refunds: ct,
  cash: { accounts: [], total_closing_cash: '0.00' },
  shifts: { items: [], difference_total: '0.00' },
  eta: null,
};
const stored = {
  id: ID,
  branch_id: BR,
  branch_name: 'Main',
  business_date: '2026-10-20',
  status: 'closed',
  totals,
  issues: [],
  note: null,
  closed_by: { id: ID, name: 'Owner' },
  closed_at: ts,
  reopened_by: null,
  reopened_at: null,
  reopen_reason: null,
  drift: false,
};

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'BRANCH_MANAGER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('K04 day close service', () => {
  it('lists with only the filters given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], from: '2026-09-21', to: '2026-10-20' }, error: null });
    await listDayCloses(ctx, { status: 'closed' });
    expect(db.rpc).toHaveBeenCalledWith('list_day_closes', { p_status: 'closed' });
  });

  it('previews a branch and day', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: {
        branch_id: BR,
        branch_name: 'Main',
        business_date: '2026-10-20',
        status: 'open',
        is_today: true,
        totals,
        issues: [],
        hash: HASH,
        last_close: null,
      },
      error: null,
    });
    const out = await getPreview(ctx, { branch_id: BR, date: '2026-10-20' });
    expect(out.hash).toBe(HASH);
    expect(db.rpc).toHaveBeenCalledWith('get_day_close_preview', {
      p_branch_id: BR,
      p_business_date: '2026-10-20',
    });
  });

  it('closes with the hash and a trimmed note; an empty note is not sent', async () => {
    const { db, ctx } = setup();
    db.queue({ data: stored, error: null });
    await closeDay(ctx, {
      branch_id: BR,
      business_date: '2026-10-20',
      preview_hash: HASH,
      note: '  ETA down  ',
    });
    expect(db.rpc).toHaveBeenCalledWith('close_day', {
      p_branch_id: BR,
      p_business_date: '2026-10-20',
      p_preview_hash: HASH,
      p_note: 'ETA down',
    });
    db.queue({ data: stored, error: null });
    await closeDay(ctx, {
      branch_id: BR,
      business_date: '2026-10-20',
      preview_hash: HASH,
      note: ' ',
    });
    expect(db.rpc).toHaveBeenLastCalledWith('close_day', {
      p_branch_id: BR,
      p_business_date: '2026-10-20',
      p_preview_hash: HASH,
    });
  });

  it('maps the close errors with their details', async () => {
    const { db, ctx } = setup();
    const body = { branch_id: BR, business_date: '2026-10-20', preview_hash: HASH };
    db.queue({
      data: null,
      error: {
        message: 'DAY_ALREADY_CLOSED: 2026-10-20',
        code: 'P0001',
        details: `{"id":"${ID}"}`,
      },
    });
    await expect(closeDay(ctx, body)).rejects.toMatchObject({
      statusCode: 409,
      code: 'DAY_ALREADY_CLOSED',
      details: { id: ID },
    });
    const issue = {
      code: 'SHIFT_OPEN',
      severity: 'blocking',
      params: { number: 'X' },
      link: { kind: 'shift', id: ID },
    };
    db.queue({
      data: null,
      error: {
        message: 'DAY_CLOSE_BLOCKED: 2026-10-20',
        code: 'P0001',
        details: JSON.stringify({ issues: [issue] }),
      },
    });
    await expect(closeDay(ctx, body)).rejects.toMatchObject({
      statusCode: 409,
      code: 'DAY_CLOSE_BLOCKED',
      details: { issues: [issue] },
    });
    db.queue({ data: null, error: { message: 'DAY_CHANGED: something', code: 'P0001' } });
    await expect(closeDay(ctx, body)).rejects.toMatchObject({
      statusCode: 409,
      code: 'DAY_CHANGED',
    });
    db.queue({ data: null, error: { message: 'NOTE_REQUIRED: warnings', code: 'P0001' } });
    await expect(closeDay(ctx, body)).rejects.toMatchObject({
      statusCode: 422,
      code: 'NOTE_REQUIRED',
    });
  });

  it('reads, reopens and answers the alerts', async () => {
    const { db, ctx } = setup();
    db.queue({ data: stored, error: null });
    expect((await getDayClose(ctx, ID)).drift).toBe(false);
    expect(db.rpc).toHaveBeenCalledWith('get_day_close', { p_id: ID });
    db.queue({
      data: { ...stored, status: 'reopened', reopened_at: ts, reopen_reason: 'Late receipt' },
      error: null,
    });
    await reopenDay(ctx, ID, { reason: 'Late receipt' });
    expect(db.rpc).toHaveBeenLastCalledWith('reopen_day', { p_id: ID, p_reason: 'Late receipt' });
    db.queue({ data: null, error: { message: 'DAY_NOT_CLOSED', code: 'P0001' } });
    await expect(reopenDay(ctx, ID, { reason: 'Again' })).rejects.toMatchObject({
      statusCode: 409,
      code: 'DAY_NOT_CLOSED',
    });
    db.queue({ data: { branches: [] }, error: null });
    expect((await getAlerts(ctx)).branches).toEqual([]);
  });

  it('maps the database closed-day refusal and denials', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'PERMISSION_DENIED: day.reopen', code: '42501' } });
    await expect(reopenDay(ctx, ID, { reason: 'Late receipt' })).rejects.toMatchObject({
      statusCode: 403,
      code: 'PERMISSION_DENIED',
    });
    db.queue({ data: null, error: { message: 'NOT_FOUND: day close', code: 'P0001' } });
    await expect(getDayClose(ctx, ID)).rejects.toMatchObject({
      statusCode: 404,
      code: 'NOT_FOUND',
    });
  });
});
