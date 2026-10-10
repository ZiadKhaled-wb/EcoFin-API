import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  closeShift,
  getCurrentShift,
  getShift,
  listShiftVaults,
  listShifts,
  moveShiftCash,
  openShift,
} from './shifts.service';

const ID = 'a0600000-0000-4000-8000-000000000001';
const BRANCH = 'a0600000-0000-4000-8000-000000000002';
const SAFE = 'a0600000-0000-4000-8000-000000000003';
const DEVICE = 'a0600000-0000-4000-8000-000000000004';
const EMPLOYEE = 'a0600000-0000-4000-8000-000000000005';
const KEY = 'shift-key-0001';
const ts = '2026-10-11T08:00:00.000Z';

const header = {
  id: ID,
  number: 'MAIN-SH-26-000001',
  branch_id: BRANCH,
  device_id: null,
  device_name: null,
  employee_id: EMPLOYEE,
  employee_name: 'Mona Cashier',
  drawer_account_id: SAFE,
  status: 'open',
  opening_float: '500.00',
  opened_at: ts,
  closed_at: null,
  closed_by_name: null,
  expected_cash: '500.00',
  counted_cash: null,
  difference: null,
  count_breakdown: null,
  difference_reason: null,
  sales_total: '0.00',
  payment_totals: { cash: '0.00', bank_transfer: '0.00', store_credit: '0.00' },
};
const shift = { ...header, movements: [] };

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'CASHIER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('K02 shift service', () => {
  it('opens with the key; the safe and the device only when given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: shift, error: null });
    await openShift(ctx, { branch_id: BRANCH, opening_float: '0' }, KEY);
    expect(db.rpc).toHaveBeenCalledWith('open_shift', {
      p_branch_id: BRANCH,
      p_opening_float: '0',
      p_idempotency_key: KEY,
    });
    db.queue({ data: shift, error: null });
    await openShift(
      ctx,
      { branch_id: BRANCH, opening_float: '500.00', vault_id: SAFE, device_id: DEVICE },
      KEY,
    );
    expect(db.rpc).toHaveBeenLastCalledWith('open_shift', {
      p_branch_id: BRANCH,
      p_opening_float: '500.00',
      p_idempotency_key: KEY,
      p_vault_id: SAFE,
      p_device_id: DEVICE,
    });
  });

  it('moves cash with the key and closes with the counts; the reason and safe only when given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: shift, error: null });
    await moveShiftCash(
      ctx,
      ID,
      { direction: 'out', amount: '200.00', vault_id: SAFE, note: 'Too much' },
      KEY,
    );
    expect(db.rpc).toHaveBeenLastCalledWith('move_shift_cash', {
      p_shift_id: ID,
      p_direction: 'out',
      p_amount: '200.00',
      p_vault_id: SAFE,
      p_note: 'Too much',
      p_idempotency_key: KEY,
    });
    db.queue({
      data: { ...shift, status: 'closed', closed_at: ts, counted_cash: '0.00' },
      error: null,
    });
    await closeShift(ctx, ID, { counts: {} });
    expect(db.rpc).toHaveBeenLastCalledWith('close_shift', { p_id: ID, p_counts: {} });
    db.queue({
      data: { ...shift, status: 'closed', closed_at: ts, counted_cash: '390.00' },
      error: null,
    });
    await closeShift(ctx, ID, {
      counts: { '200': 1, '100': 1, '50': 1, '20': 2 },
      vault_id: SAFE,
      difference_reason: 'Ten short',
    });
    expect(db.rpc).toHaveBeenLastCalledWith('close_shift', {
      p_id: ID,
      p_counts: { '200': 1, '100': 1, '50': 1, '20': 2 },
      p_vault_id: SAFE,
      p_difference_reason: 'Ten short',
    });
  });

  it('maps SHIFT_DIFFERENCE_REASON_REQUIRED with its details', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        code: 'P0001',
        message: 'SHIFT_DIFFERENCE_REASON_REQUIRED: expected 400.00, counted 390.00',
        details: JSON.stringify({ expected: '400.00', counted: '390.00', difference: '-10.00' }),
      },
    });
    await expect(
      closeShift(ctx, ID, { counts: { '200': 1 }, vault_id: SAFE }),
    ).rejects.toMatchObject({
      code: 'SHIFT_DIFFERENCE_REASON_REQUIRED',
      details: { expected: '400.00', counted: '390.00', difference: '-10.00' },
    });
  });

  it('reads: no open shift is null; one shift; the list with filters; the vaults', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: null });
    expect(await getCurrentShift(ctx)).toEqual({ shift: null });
    db.queue({ data: shift, error: null });
    expect((await getCurrentShift(ctx)).shift?.id).toBe(ID);
    db.queue({ data: shift, error: null });
    await getShift(ctx, ID);
    expect(db.rpc).toHaveBeenLastCalledWith('get_shift', { p_id: ID });
    db.queue({ data: { items: [header], total: 21 }, error: null });
    const list = await listShifts(ctx, {
      employee_id: EMPLOYEE,
      status: 'closed',
      from: '2026-10-01',
      page: 2,
      pageSize: 20,
    });
    expect(list).toMatchObject({ page: 2, pageSize: 20, total: 21 });
    expect(db.rpc).toHaveBeenLastCalledWith('list_shifts', {
      p_employee_id: EMPLOYEE,
      p_status: 'closed',
      p_from: '2026-10-01',
      p_limit: 20,
      p_offset: 20,
    });
    db.queue({ data: { items: [{ id: SAFE, name: 'Main safe' }] }, error: null });
    expect((await listShiftVaults(ctx, BRANCH)).items).toHaveLength(1);
    expect(db.rpc).toHaveBeenLastCalledWith('list_shift_vaults', { p_branch_id: BRANCH });
  });
});
