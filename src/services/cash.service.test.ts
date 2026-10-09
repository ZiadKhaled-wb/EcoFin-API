import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import {
  createCashAccount,
  createCashTransfer,
  getCashAccount,
  getCashLedger,
  getCashTransfer,
  listCashAccounts,
  listCashTransfers,
  postCashOpening,
  renameCashAccount,
  setCashAccountActive,
} from './cash.service';

const SAFE = 'a0590000-0000-4000-8000-000000000001';
const BANK = 'a0590000-0000-4000-8000-000000000002';
const BRANCH = 'a0590000-0000-4000-8000-000000000003';
const account = (extra: Record<string, unknown> = {}) => ({
  id: SAFE,
  name: 'Main safe',
  kind: 'safe',
  branch_id: BRANCH,
  branch_name: 'Main',
  is_active: true,
  archived_at: null,
  balance: '3800.00',
  is_default: true,
  created_at: '2026-10-11T08:00:00.000Z',
  updated_at: '2026-10-11T08:00:00.000Z',
  ...extra,
});
const transfer = {
  id: 'a0590000-0000-4000-8000-000000000004',
  number: 'MAIN-CX-26-000001',
  from_account_id: SAFE,
  from_account_name: 'Main safe',
  to_account_id: BANK,
  to_account_name: 'NBE',
  amount: '1200.00',
  note: null,
  business_date: '2026-10-11',
  created_by_name: 'Owner',
  created_at: '2026-10-11T08:00:00.000Z',
};

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

describe('K01 cash service', () => {
  it('lists accounts with the filters given, and only the status otherwise', async () => {
    const { db, ctx } = setup();
    db.queue({ data: [account()], error: null });
    expect(await listCashAccounts(ctx, { status: 'all', branch_id: BRANCH, kind: 'safe' })).toEqual(
      [account()],
    );
    expect(db.rpc).toHaveBeenCalledWith('list_cash_accounts', {
      p_status: 'all',
      p_branch_id: BRANCH,
      p_kind: 'safe',
    });
    db.queue({ data: [], error: null });
    await listCashAccounts(ctx, { status: 'active' });
    expect(db.rpc).toHaveBeenLastCalledWith('list_cash_accounts', { p_status: 'active' });
  });

  it('gets an account and refuses a malformed row (balance as a number)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: account(), error: null });
    expect(await getCashAccount(ctx, SAFE)).toEqual(account());
    db.queue({ data: account({ balance: 3800 }), error: null });
    await expect(getCashAccount(ctx, SAFE)).rejects.toThrow();
  });

  it('reads the ledger with paging and dates, adding page and pageSize', async () => {
    const { db, ctx } = setup();
    const ledger = {
      account: account(),
      from: '2026-10-01',
      to: null,
      opening_balance: '0.00',
      closing_balance: '3800.00',
      items: [],
      total: 0,
    };
    db.queue({ data: ledger, error: null });
    expect(await getCashLedger(ctx, SAFE, { page: 2, pageSize: 20, from: '2026-10-01' })).toEqual({
      ...ledger,
      page: 2,
      pageSize: 20,
    });
    expect(db.rpc).toHaveBeenCalledWith('list_cash_account_movements', {
      p_id: SAFE,
      p_from: '2026-10-01',
      p_limit: 20,
      p_offset: 20,
    });
  });

  it('creates a safe in a branch and a shop-wide bank (no branch sent)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: account(), error: null });
    await createCashAccount(ctx, { name: 'Main safe', kind: 'safe', branch_id: BRANCH });
    expect(db.rpc).toHaveBeenCalledWith('create_cash_account', {
      p_name: 'Main safe',
      p_kind: 'safe',
      p_branch_id: BRANCH,
    });
    db.queue({ data: account({ kind: 'bank', branch_id: null, branch_name: null }), error: null });
    await createCashAccount(ctx, { name: 'NBE', kind: 'bank', branch_id: null });
    expect(db.rpc).toHaveBeenLastCalledWith('create_cash_account', {
      p_name: 'NBE',
      p_kind: 'bank',
    });
  });

  it('renames, deactivates and reactivates', async () => {
    const { db, ctx } = setup();
    db.queue({ data: account({ name: 'Rear' }), error: null });
    await renameCashAccount(ctx, SAFE, 'Rear');
    expect(db.rpc).toHaveBeenCalledWith('rename_cash_account', { p_id: SAFE, p_name: 'Rear' });
    db.queue({ data: account({ is_active: false }), error: null });
    await setCashAccountActive(ctx, SAFE, false);
    expect(db.rpc).toHaveBeenLastCalledWith('set_cash_account_active', {
      p_id: SAFE,
      p_active: false,
    });
  });

  it('posts an opening with the key', async () => {
    const { db, ctx } = setup();
    db.queue({ data: account({ balance: '5000.00' }), error: null });
    expect(
      (await postCashOpening(ctx, SAFE, { amount: '5000.00', note: 'Day one' }, 'key-12345678'))
        .balance,
    ).toBe('5000.00');
    expect(db.rpc).toHaveBeenCalledWith('post_cash_opening', {
      p_id: SAFE,
      p_amount: '5000.00',
      p_note: 'Day one',
      p_idempotency_key: 'key-12345678',
    });
  });

  it('creates a transfer (no note sends an empty one) and reads transfers', async () => {
    const { db, ctx } = setup();
    db.queue({ data: transfer, error: null });
    expect(
      await createCashTransfer(
        ctx,
        { from_account_id: SAFE, to_account_id: BANK, amount: '1200.00' },
        'key-12345678',
      ),
    ).toEqual(transfer);
    expect(db.rpc).toHaveBeenCalledWith('create_cash_transfer', {
      p_from: SAFE,
      p_to: BANK,
      p_amount: '1200.00',
      p_note: '',
      p_idempotency_key: 'key-12345678',
    });
    db.queue({ data: { items: [transfer], total: 1 }, error: null });
    expect(
      await listCashTransfers(ctx, { page: 1, pageSize: 50, account_id: SAFE, to: '2026-10-11' }),
    ).toEqual({ items: [transfer], total: 1, page: 1, pageSize: 50 });
    expect(db.rpc).toHaveBeenLastCalledWith('list_cash_transfers', {
      p_account_id: SAFE,
      p_to: '2026-10-11',
      p_limit: 50,
      p_offset: 0,
    });
    db.queue({ data: transfer, error: null });
    expect(await getCashTransfer(ctx, transfer.id)).toEqual(transfer);
  });

  it('maps the database errors to contract codes', async () => {
    const { db, ctx } = setup();
    const cases: [string, string, number][] = [
      ['INSUFFICIENT_FUNDS: cash account x', 'INSUFFICIENT_FUNDS', 409],
      ['DAY_CLOSED: 2026-10-11 is closed for this branch', 'DAY_CLOSED', 409],
      ['CASH_ACCOUNT_NOT_FOUND', 'CASH_ACCOUNT_NOT_FOUND', 404],
      ['CASH_TRANSFER_NOT_FOUND', 'CASH_TRANSFER_NOT_FOUND', 404],
      ['CASH_ACCOUNT_HAS_BALANCE', 'CASH_ACCOUNT_HAS_BALANCE', 409],
      ['CASH_ACCOUNT_IS_DEFAULT', 'CASH_ACCOUNT_IS_DEFAULT', 409],
      ['CASH_ACCOUNT_HAS_MOVEMENTS', 'CASH_ACCOUNT_HAS_MOVEMENTS', 409],
      ['TRANSFER_SAME_ACCOUNT', 'TRANSFER_SAME_ACCOUNT', 400],
    ];
    for (const [message, code, status] of cases) {
      expect(mapDbError({ message })).toMatchObject({ code, statusCode: status });
      db.queue({ data: null, error: { message } });
      await expect(getCashTransfer(ctx, transfer.id)).rejects.toMatchObject({ code });
    }
  });
});
