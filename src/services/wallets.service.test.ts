import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  getCollectorRoute,
  getMyWallet,
  listWalletMovements,
  listWallets,
  postFieldCollection,
  setCustomerCollector,
  settleWallet,
} from './wallets.service';

const ID = 'a0900000-0000-4000-8000-000000000001';
const ts = '2026-10-19T08:00:00.000Z';
const settlement = {
  id: ID,
  number: 'MAIN-CX-26-000001',
  business_date: '2026-10-19',
  wallet_id: ID,
  wallet_name: 'Wallet · Collector',
  collector: { id: ID, name: 'Collector' },
  to_account_id: ID,
  to_account_name: 'Safe',
  handed: '900.00',
  shortage: '100.00',
  reason: 'Torn note',
  balance_after: '500.00',
  created_by_name: 'Accountant',
  created_at: ts,
};
const walletRow = {
  id: ID,
  name: 'Wallet · Collector',
  is_active: true,
  collector: { id: ID, name: 'Collector' },
  branch_id: ID,
  branch_name: 'Main',
  balance: '500.00',
  oldest_unsettled_date: '2026-10-19',
  last_settlement: null,
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

describe('N06 wallets service', () => {
  it('settles with the key and the body as given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: settlement, error: null });
    const body = {
      to_account_id: ID,
      handed: '900.00',
      shortage: '100.00',
      reason: 'Torn note',
      expected_balance: '1500.00',
    };
    const out = await settleWallet(ctx, ID, body, 'key-12345678');
    expect(out.shortage).toBe('100.00');
    expect(db.rpc).toHaveBeenCalledWith('settle_collector_wallet', {
      p_id: ID,
      p_body: body,
      p_idempotency_key: 'key-12345678',
    });
  });

  it('maps a stale balance to WALLET_BALANCE_CHANGED with the balance', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        message: 'WALLET_BALANCE_CHANGED: the wallet holds 1500.00',
        code: 'P0001',
        details: '{"balance":"1500.00"}',
      },
    });
    await expect(
      settleWallet(
        ctx,
        ID,
        { to_account_id: ID, handed: '1.00', expected_balance: '9.00' },
        'key-12345678',
      ),
    ).rejects.toMatchObject({ statusCode: 409, code: 'WALLET_BALANCE_CHANGED' });
  });

  it('maps the assignment errors', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'CUSTOMER_NOT_ASSIGNED', code: 'P0001' } });
    await expect(
      postFieldCollection(
        ctx,
        {
          customer_id: ID,
          contracts: [{ contract_id: ID, amount: '1.00' }],
          payments: [{ method: 'cash', amount: '1.00' }],
        },
        'key-12345678',
      ),
    ).rejects.toMatchObject({ statusCode: 403, code: 'CUSTOMER_NOT_ASSIGNED' });
    db.queue({ data: null, error: { message: 'COLLECTOR_INVALID', code: 'P0001' } });
    await expect(setCustomerCollector(ctx, ID, { employee_id: ID })).rejects.toMatchObject({
      statusCode: 422,
      code: 'COLLECTOR_INVALID',
    });
  });

  it('reads the wallets, my wallet, a ledger and a route', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [walletRow] }, error: null });
    expect((await listWallets(ctx, {})).items).toHaveLength(1);
    expect(db.rpc).toHaveBeenCalledWith('list_collector_wallets', { p_filters: {} });
    db.queue({
      data: {
        wallet: null,
        balance: '0.00',
        today: { count: 0, amount: '0.00', cash: '0.00' },
        oldest_unsettled_date: null,
        last_settlement: null,
      },
      error: null,
    });
    expect((await getMyWallet(ctx)).balance).toBe('0.00');
    db.queue({ data: { wallet: walletRow, items: [], next_cursor: null }, error: null });
    expect((await listWalletMovements(ctx, ID, { limit: 10 })).wallet.balance).toBe('500.00');
    expect(db.rpc).toHaveBeenCalledWith('list_wallet_movements', {
      p_id: ID,
      p_filters: { limit: 10 },
    });
    db.queue({
      data: {
        employee_id: ID,
        employee_name: 'Collector',
        date: '2026-10-19',
        stops: [],
        totals: { customers: 0, amount_due: '0.00', amount_overdue: '0.00' },
      },
      error: null,
    });
    expect((await getCollectorRoute(ctx, { date: '2026-10-19' })).stops).toEqual([]);
  });

  it('logs only the message and the code of a database failure', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'boom', code: 'XX000' } });
    await expect(getMyWallet(ctx)).rejects.toMatchObject({ statusCode: 500 });
  });
});
