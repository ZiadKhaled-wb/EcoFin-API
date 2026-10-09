import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  getSupplierPayment,
  listOpenSupplierInvoices,
  listSupplierPayments,
  postSupplierPayment,
  reverseSupplierPayment,
} from './supplierPayments.service';

const ID = 'a0580000-0000-4000-8000-000000000020';
const SUPPLIER = 'a0580000-0000-4000-8000-000000000001';
const BRANCH = 'a0580000-0000-4000-8000-000000000002';
const SAFE = 'a0580000-0000-4000-8000-000000000003';
const INVOICE = 'a0580000-0000-4000-8000-000000000004';
const KEY = 'sp-key-0001';

const header = {
  id: ID,
  number: 'MAIN-SP-26-000001',
  supplier_id: SUPPLIER,
  supplier_name: 'Nile Traders',
  branch_id: BRANCH,
  cash_account_id: SAFE,
  cash_account_name: 'Main safe',
  amount: '3000.00',
  reference: null,
  business_date: '2026-10-11',
  paid_at: '2026-10-11T08:00:00.000Z',
  reverses_payment_id: null,
  reversed_by_payment_id: null,
  reason: null,
  created_by_name: 'Owner',
};
const payment = { ...header, allocations: [] };

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

describe('U03 supplier payment service', () => {
  it('posts with the key; reference and allocations only when given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: payment, error: null });
    const body = { supplier_id: SUPPLIER, branch_id: BRANCH, cash_account_id: SAFE };
    await postSupplierPayment(ctx, { ...body, amount: '3000.00', reference: null }, KEY);
    expect(db.rpc).toHaveBeenCalledWith('post_supplier_payment', {
      p_supplier_id: SUPPLIER,
      p_branch_id: BRANCH,
      p_cash_account_id: SAFE,
      p_amount: '3000.00',
      p_idempotency_key: KEY,
    });

    db.queue({ data: payment, error: null });
    const allocations = [{ purchase_invoice_id: INVOICE, amount: '3000.00' }];
    await postSupplierPayment(
      ctx,
      { ...body, amount: '3000.00', reference: 'TRX-1', allocations },
      KEY,
    );
    expect(db.rpc).toHaveBeenLastCalledWith('post_supplier_payment', {
      p_supplier_id: SUPPLIER,
      p_branch_id: BRANCH,
      p_cash_account_id: SAFE,
      p_amount: '3000.00',
      p_idempotency_key: KEY,
      p_reference: 'TRX-1',
      p_allocations: allocations,
    });
  });

  it('maps PAYMENT_EXCEEDS_OUTSTANDING with its details and INSUFFICIENT_FUNDS', async () => {
    const { db, ctx } = setup();
    const body = { supplier_id: SUPPLIER, branch_id: BRANCH, cash_account_id: SAFE };
    db.queue({
      data: null,
      error: {
        code: 'P0001',
        message: 'PAYMENT_EXCEEDS_OUTSTANDING: the supplier is owed 4100.00',
        details: JSON.stringify({ purchase_invoice_id: null, outstanding: '4100.00' }),
      },
    });
    await expect(
      postSupplierPayment(ctx, { ...body, amount: '5000.00' }, KEY),
    ).rejects.toMatchObject({
      code: 'PAYMENT_EXCEEDS_OUTSTANDING',
      details: { purchase_invoice_id: null, outstanding: '4100.00' },
    });
    db.queue({
      data: null,
      error: { code: '23514', message: `INSUFFICIENT_FUNDS: cash account ${SAFE}`, details: null },
    });
    await expect(
      postSupplierPayment(ctx, { ...body, amount: '5000.00' }, KEY),
    ).rejects.toMatchObject({ code: 'INSUFFICIENT_FUNDS' });
  });

  it('reverses with the reason and the key; reads one, the list and the open invoices', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { ...payment, reverses_payment_id: ID, reason: 'Wrong' }, error: null });
    await reverseSupplierPayment(ctx, ID, 'Wrong supplier', KEY);
    expect(db.rpc).toHaveBeenLastCalledWith('reverse_supplier_payment', {
      p_id: ID,
      p_reason: 'Wrong supplier',
      p_idempotency_key: KEY,
    });

    db.queue({ data: payment, error: null });
    await getSupplierPayment(ctx, ID);
    expect(db.rpc).toHaveBeenLastCalledWith('get_supplier_payment', { p_id: ID });

    db.queue({ data: { items: [header], total: 31 }, error: null });
    const list = await listSupplierPayments(ctx, {
      supplier_id: SUPPLIER,
      to: '2026-10-11',
      include_reversals: false,
      page: 2,
      pageSize: 30,
    });
    expect(list).toMatchObject({ page: 2, pageSize: 30, total: 31 });
    expect(db.rpc).toHaveBeenLastCalledWith('list_supplier_payments', {
      p_supplier_id: SUPPLIER,
      p_to: '2026-10-11',
      p_include_reversals: false,
      p_limit: 30,
      p_offset: 30,
    });

    db.queue({ data: { items: [], total_outstanding: '0.00' }, error: null });
    const open = await listOpenSupplierInvoices(ctx, SUPPLIER);
    expect(open.total_outstanding).toBe('0.00');
    expect(db.rpc).toHaveBeenLastCalledWith('list_open_supplier_invoices', {
      p_supplier_id: SUPPLIER,
    });
  });

  it('refuses a malformed row', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { ...payment, amount: 3000 }, error: null });
    await expect(getSupplierPayment(ctx, ID)).rejects.toThrow();
  });
});
