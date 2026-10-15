import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  getContractSchedule,
  getCustomerAccount,
  getCustomerStatement,
} from './customerAccount.service';

const ID = 'a0740000-0000-4000-8000-000000000001';
const CUSTOMER = 'a0740000-0000-4000-8000-000000000002';
const CONTRACT = 'a0740000-0000-4000-8000-000000000003';
const AT = '2026-10-16T09:00:00.000Z';

const zeroAging = {
  not_yet_due: '0.00',
  late_1_30: '0.00',
  late_31_60: '0.00',
  late_61_90: '0.00',
  late_90_plus: '0.00',
};
const head = { id: CUSTOMER, full_name: 'Quiet Customer', status: 'active', phones: [] };
const contract = {
  id: CONTRACT,
  number: 'BR1-CT-26-000001',
  status: 'active',
  branch: { id: ID, name: 'Main' },
  sale_id: null,
  sale_number: null,
  issued_at: AT,
  is_migrated: true,
  cash_price: '4000.00',
  down_payment: '0.00',
  financed_amount: '4000.00',
  markup_amount: '0.00',
  total_payable: '4000.00',
  contract_total: '4000.00',
  paid: '0.00',
  remaining: '4000.00',
  fees_due: '0.00',
  overdue_amount: '0.00',
  overdue_lines: 0,
  max_days_late: null,
  next_due_date: '2026-11-16',
  installments_count: 1,
  frequency: 'monthly',
  first_due_date: '2026-11-16',
};
const account = (extra: Record<string, unknown> = {}) => ({
  customer: head,
  balance: {
    contract_totals: '0.00',
    payments: '0.00',
    returns: '0.00',
    open_balance: '0.00',
    fees_due: '0.00',
    total_due: '0.00',
    store_credit: '0.00',
    credit_limit: '0.00',
    available: '0.00',
  },
  overdue: {
    overdue_amount: '0.00',
    overdue_lines: 0,
    max_days_late: null,
    next_due_date: null,
    next_due_amount: null,
    aging: zeroAging,
  },
  totals: {
    purchases_count: 0,
    purchases_total: '0.00',
    returns_count: 0,
    returns_total: '0.00',
    payments_in: '0.00',
    payments_out: '0.00',
    last_purchase_at: null,
    last_payment_at: null,
  },
  contracts: [],
  recent_payments: [],
  recent_returns: [],
  documents_count: 0,
  ...extra,
});
const statement = {
  customer: head,
  from: null,
  to: null,
  opening_balance: '0.00',
  closing_balance: '0.00',
  totals: { debit: '0.00', credit: '0.00' },
  rows: [],
};

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

describe('R02 customer account service', () => {
  it('reads the account through the database function', async () => {
    const { db, ctx } = setup();
    db.queue({ data: account(), error: null });
    expect((await getCustomerAccount(ctx, CUSTOMER)).balance.open_balance).toBe('0.00');
    expect(db.rpc).toHaveBeenCalledWith('get_customer_account', { p_customer_id: CUSTOMER });
  });

  it('refuses an answer that is not the contract shape', async () => {
    const { db, ctx } = setup();
    db.queue({ data: account({ documents_count: -1 }), error: null });
    await expect(getCustomerAccount(ctx, CUSTOMER)).rejects.toThrow();
  });

  it('maps CUSTOMER_NOT_FOUND from the database to a 404', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'CUSTOMER_NOT_FOUND', code: 'P0001' } });
    await expect(getCustomerAccount(ctx, CUSTOMER)).rejects.toMatchObject({
      code: 'CUSTOMER_NOT_FOUND',
      statusCode: 404,
    });
  });

  it('reads a contract schedule with both ids and maps CONTRACT_NOT_FOUND', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { contract, lines: [], charges: [] }, error: null });
    expect((await getContractSchedule(ctx, CUSTOMER, CONTRACT)).contract.number).toBe(
      'BR1-CT-26-000001',
    );
    expect(db.rpc).toHaveBeenCalledWith('get_customer_contract_schedule', {
      p_customer_id: CUSTOMER,
      p_contract_id: CONTRACT,
    });
    db.queue({ data: null, error: { message: 'CONTRACT_NOT_FOUND', code: 'P0001' } });
    await expect(getContractSchedule(ctx, CUSTOMER, CONTRACT)).rejects.toMatchObject({
      code: 'CONTRACT_NOT_FOUND',
      statusCode: 404,
    });
  });

  it('sends only the dates it has to the statement', async () => {
    const { db, ctx } = setup();
    db.queue({ data: statement, error: null });
    await getCustomerStatement(ctx, CUSTOMER, {});
    expect(db.rpc).toHaveBeenLastCalledWith('customer_statement', { p_customer_id: CUSTOMER });
    db.queue({ data: { ...statement, from: '2026-10-01', to: '2026-10-16' }, error: null });
    await getCustomerStatement(ctx, CUSTOMER, { from: '2026-10-01', to: '2026-10-16' });
    expect(db.rpc).toHaveBeenLastCalledWith('customer_statement', {
      p_customer_id: CUSTOMER,
      p_from: '2026-10-01',
      p_to: '2026-10-16',
    });
  });

  it('maps a database VALIDATION_FAILED to a 400', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'VALIDATION_FAILED: to', code: 'P0001' } });
    await expect(
      getCustomerStatement(ctx, CUSTOMER, { from: '2020-01-01', to: '2026-01-01' }),
    ).rejects.toMatchObject({ code: 'VALIDATION_FAILED', statusCode: 400 });
  });
});
