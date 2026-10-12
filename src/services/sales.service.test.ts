import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  cancelDiscountApproval,
  decideDiscountApproval,
  getDiscountApproval,
  getSale,
  listDiscountApprovals,
  listPaymentAccounts,
  postSale,
  quoteSale,
  requestDiscountApproval,
} from './sales.service';

const ID = 'a0620000-0000-4000-8000-000000000001';
const BRANCH = 'a0620000-0000-4000-8000-000000000002';
const CHAIR = 'a0620000-0000-4000-8000-000000000003';
const CUSTOMER = 'a0620000-0000-4000-8000-000000000004';
const KEY = 'sale-key-0001';
const ts = '2026-10-12T08:00:00.000Z';

const line = {
  product_id: CHAIR,
  name_ar: 'كرسي',
  name_en: null,
  sku: 'CH',
  is_serialized: false,
  unit_id: null,
  serial: null,
  quantity: 2,
  unit_price: '250.00',
  tax_rate: '14.00',
  tax_amount: '61.40',
  line_total: '500.00',
  discount_amount: '0.00',
};
const quote = {
  prices_include_vat: true,
  lines: [
    { ...line, list_price: '250.00', overridden: false, available: 10, effective_pct: '0.00' },
  ],
  subtotal: '500.00',
  discount_total: '0.00',
  max_effective_pct: '0.00',
  tax_total: '61.40',
  total: '500.00',
  paid: '500.00',
  remaining: '0.00',
  change: '0.00',
  store_credit_balance: null,
};
const sale = {
  id: ID,
  number: 'MAIN-SL-26-000001',
  branch_id: BRANCH,
  shift_id: BRANCH,
  shift_number: 'MAIN-SH-26-000001',
  customer_id: null,
  customer_name: null,
  prices_include_vat: true,
  subtotal: '500.00',
  discount_total: '0.00',
  discount_reason: null,
  tax_total: '61.40',
  total: '500.00',
  business_date: '2026-10-12',
  issued_at: ts,
  created_by_name: 'Mona',
  lines: [{ ...line, id: ID, line_no: 1, warranty_until: null }],
  payments: [],
  paid_total: '500.00',
  change_total: '0.00',
};
const lines = [{ product_id: CHAIR, quantity: 2 }];

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

describe('S01 sale service', () => {
  it('quotes the cart; the customer only when given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: quote, error: null });
    expect((await quoteSale(ctx, { lines })).total).toBe('500.00');
    expect(db.rpc).toHaveBeenLastCalledWith('quote_sale', { p_lines: lines });
    db.queue({ data: quote, error: null });
    await quoteSale(ctx, { lines, customer_id: CUSTOMER });
    expect(db.rpc).toHaveBeenLastCalledWith('quote_sale', {
      p_lines: lines,
      p_customer_id: CUSTOMER,
    });
  });

  it('posts with the key and the total the cashier saw', async () => {
    const { db, ctx } = setup();
    db.queue({ data: sale, error: null });
    expect((await postSale(ctx, { lines, expected_total: '500.00' }, KEY)).number).toBe(
      'MAIN-SL-26-000001',
    );
    expect(db.rpc).toHaveBeenLastCalledWith('post_sale', {
      p_lines: lines,
      p_expected_total: '500.00',
      p_idempotency_key: KEY,
    });
    db.queue({ data: sale, error: null });
    await postSale(ctx, { lines, expected_total: '500.00', customer_id: CUSTOMER }, KEY);
    expect(db.rpc).toHaveBeenLastCalledWith('post_sale', {
      p_lines: lines,
      p_expected_total: '500.00',
      p_idempotency_key: KEY,
      p_customer_id: CUSTOMER,
    });
  });

  it('S02: the payment lines go to the quote and to the sale, and only when given', async () => {
    const { db, ctx } = setup();
    const payments = [
      { method: 'cash' as const, amount: '250.00', tendered: '300.00' },
      {
        method: 'bank_transfer' as const,
        amount: '250.00',
        cash_account_id: BRANCH,
        reference: 'TRX-1',
      },
    ];
    db.queue({ data: { ...quote, paid: '500.00', change: '50.00' }, error: null });
    expect((await quoteSale(ctx, { lines, payments })).change).toBe('50.00');
    expect(db.rpc).toHaveBeenLastCalledWith('quote_sale', { p_lines: lines, p_payments: payments });
    db.queue({ data: sale, error: null });
    await postSale(ctx, { lines, expected_total: '500.00', payments }, KEY);
    expect(db.rpc).toHaveBeenLastCalledWith('post_sale', {
      p_lines: lines,
      p_expected_total: '500.00',
      p_idempotency_key: KEY,
      p_payments: payments,
    });
  });

  it('S02: PAYMENT_TOTAL_MISMATCH and INSUFFICIENT_STORE_CREDIT carry their details', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        code: 'P0001',
        message: 'PAYMENT_TOTAL_MISMATCH: the payments add up to 499.00, the sale to 500.00',
        details: '{"total":"500.00","paid":"499.00"}',
      },
    });
    await expect(postSale(ctx, { lines, expected_total: '500.00' }, KEY)).rejects.toMatchObject({
      statusCode: 400,
      code: 'PAYMENT_TOTAL_MISMATCH',
      details: { total: '500.00', paid: '499.00' },
    });
    db.queue({
      data: null,
      error: {
        code: 'P0001',
        message: 'INSUFFICIENT_STORE_CREDIT: the balance is 300.00',
        details: '{"balance":"300.00"}',
      },
    });
    await expect(postSale(ctx, { lines, expected_total: '500.00' }, KEY)).rejects.toMatchObject({
      statusCode: 409,
      code: 'INSUFFICIENT_STORE_CREDIT',
      details: { balance: '300.00' },
    });
  });

  it('S02: lists the banks a transfer can go into', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [{ id: BRANCH, name: 'NBE' }] }, error: null });
    expect((await listPaymentAccounts(ctx)).items[0]?.name).toBe('NBE');
    expect(db.rpc).toHaveBeenLastCalledWith('list_sale_payment_accounts');
  });

  it('PRICE_CHANGED and OUT_OF_STOCK carry their details; other refusals keep their code', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        code: 'P0001',
        message: 'PRICE_CHANGED: expected 240.00, the total is 250.00',
        details: '{"expected_total":"240.00","total":"250.00"}',
      },
    });
    await expect(postSale(ctx, { lines, expected_total: '240.00' }, KEY)).rejects.toMatchObject({
      statusCode: 409,
      code: 'PRICE_CHANGED',
      details: { expected_total: '240.00', total: '250.00' },
    });
    db.queue({
      data: null,
      error: {
        code: 'P0001',
        message: 'OUT_OF_STOCK: CH (asked 2, available 1)',
        details: `{"product_id":"${CHAIR}","requested":2,"available":1}`,
      },
    });
    await expect(postSale(ctx, { lines, expected_total: '500.00' }, KEY)).rejects.toMatchObject({
      statusCode: 409,
      code: 'OUT_OF_STOCK',
      details: { product_id: CHAIR, requested: 2, available: 1 },
    });
    // The ledger trigger's own OUT_OF_STOCK has no JSON detail: the code alone is passed on.
    db.queue({
      data: null,
      error: { code: '23514', message: 'OUT_OF_STOCK: product x at branch y' },
    });
    const plain = await postSale(ctx, { lines, expected_total: '500.00' }, KEY).catch((e) => e);
    expect(plain).toMatchObject({ statusCode: 409, code: 'OUT_OF_STOCK' });
    expect(plain.details).toBeUndefined();
    for (const [message, statusCode] of [
      ['SHIFT_REQUIRED: open a shift first', 409],
      ['SHIFT_CLOSED: the shift is closed', 409],
      ['UNIT_NOT_AVAILABLE: X is sold', 409],
      ['PRODUCT_ARCHIVED: CH', 409],
      ['PRICE_OVERRIDE_DENIED: CH', 403],
      ['CUSTOMER_NOT_FOUND', 404],
      ['DAY_CLOSED: 2026-10-12 is closed for this branch', 409],
    ] as const) {
      db.queue({ data: null, error: { code: 'P0001', message } });
      await expect(postSale(ctx, { lines, expected_total: '500.00' }, KEY)).rejects.toMatchObject({
        statusCode,
        code: message.split(':')[0],
      });
    }
  });

  it('reads a sale; not found is 404; a malformed answer is not passed on', async () => {
    const { db, ctx } = setup();
    db.queue({ data: sale, error: null });
    expect((await getSale(ctx, ID)).total).toBe('500.00');
    expect(db.rpc).toHaveBeenLastCalledWith('get_sale', { p_id: ID });
    db.queue({ data: null, error: { code: 'P0001', message: 'SALE_NOT_FOUND' } });
    await expect(getSale(ctx, ID)).rejects.toMatchObject({
      statusCode: 404,
      code: 'SALE_NOT_FOUND',
    });
    db.queue({ data: null, error: null });
    await expect(postSale(ctx, { lines, expected_total: '500.00' }, KEY)).rejects.toThrow();
  });
});

describe('S03 discount service', () => {
  const discounted = [
    { product_id: CHAIR, quantity: 2, discount: { type: 'percent' as const, value: '6' } },
  ];
  const approvalId = 'a0620000-0000-4000-8000-0000000000a1';
  const approval = {
    id: approvalId,
    status: 'pending',
    branch_id: BRANCH,
    branch_name: 'Main',
    requested_by_name: 'Mona',
    requested_at: ts,
    max_effective_pct: '6.00',
    cap_pct: '5.00',
    discount_total: '30.00',
    reason: 'Regular customer',
    lines: [
      {
        product_id: CHAIR,
        sku: 'CH',
        name_ar: 'كرسي',
        name_en: null,
        quantity: 2,
        unit_price: '250.00',
        discount_amount: '30.00',
        effective_pct: '6.00',
      },
    ],
    decided_by_name: null,
    decided_at: null,
    decision_note: null,
    used: false,
  };

  it('the quote and the sale pass the discounts, the reason and the approval, only when given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: quote, error: null });
    await quoteSale(ctx, { lines: discounted, sale_discount: { type: 'amount', value: '10.00' } });
    expect(db.rpc).toHaveBeenLastCalledWith('quote_sale', {
      p_lines: discounted,
      p_sale_discount: { type: 'amount', value: '10.00' },
    });
    db.queue({ data: sale, error: null });
    await postSale(
      ctx,
      {
        lines: discounted,
        expected_total: '470.00',
        sale_discount: { type: 'amount', value: '10.00' },
        discount_reason: 'Regular customer',
        discount_approval_id: approvalId,
      },
      KEY,
    );
    expect(db.rpc).toHaveBeenLastCalledWith('post_sale', {
      p_lines: discounted,
      p_expected_total: '470.00',
      p_idempotency_key: KEY,
      p_sale_discount: { type: 'amount', value: '10.00' },
      p_discount_reason: 'Regular customer',
      p_discount_approval_id: approvalId,
    });
  });

  it('DISCOUNT_ABOVE_CAP is 403 with the line, the cap and the percent', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        code: 'P0001',
        message: 'DISCOUNT_ABOVE_CAP: line 1 is at 6.00, the cap is 5.00',
        details: '{"line_no":1,"cap_pct":"5.00","effective_pct":"6.00"}',
      },
    });
    await expect(
      postSale(ctx, { lines: discounted, expected_total: '470.00' }, KEY),
    ).rejects.toMatchObject({
      statusCode: 403,
      code: 'DISCOUNT_ABOVE_CAP',
      details: { line_no: 1, cap_pct: '5.00', effective_pct: '6.00' },
    });
  });

  it.each([
    ['APPROVAL_INVALID', 409],
    ['APPROVAL_NOT_PENDING', 409],
    ['APPROVAL_SELF', 403],
    ['APPROVAL_NOT_NEEDED', 400],
    ['APPROVAL_NOT_FOUND', 404],
    ['DISCOUNT_INVALID', 400],
    ['DISCOUNT_REASON_REQUIRED', 400],
  ])('%s maps to HTTP %i', async (code, status) => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { code: 'P0001', message: `${code}: detail` } });
    await expect(
      postSale(ctx, { lines: discounted, expected_total: '470.00' }, KEY),
    ).rejects.toMatchObject({ statusCode: status, code });
  });

  it('requests, reads, cancels, lists and decides', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: { approval_id: approvalId, max_effective_pct: '6.00', cap_pct: '5.00' },
      error: null,
    });
    const requested = await requestDiscountApproval(ctx, {
      branch_id: BRANCH,
      lines: discounted,
      reason: 'Regular customer',
    });
    expect(requested.approval_id).toBe(approvalId);
    expect(db.rpc).toHaveBeenLastCalledWith('request_discount_approval', {
      p_branch_id: BRANCH,
      p_lines: discounted,
      p_sale_discount: null,
      p_reason: 'Regular customer',
    });
    db.queue({ data: approval, error: null });
    expect((await getDiscountApproval(ctx, approvalId)).status).toBe('pending');
    expect(db.rpc).toHaveBeenLastCalledWith('get_discount_approval', {
      p_approval_id: approvalId,
    });
    db.queue({ data: { status: 'cancelled' }, error: null });
    expect((await cancelDiscountApproval(ctx, approvalId)).status).toBe('cancelled');
    expect(db.rpc).toHaveBeenLastCalledWith('cancel_discount_approval', {
      p_approval_id: approvalId,
    });
    db.queue({ data: { items: [approval] }, error: null });
    const listed = await listDiscountApprovals(ctx, {
      kind: 'discount_above_cap',
      status: 'pending',
    });
    expect(listed.items).toHaveLength(1);
    expect(db.rpc).toHaveBeenLastCalledWith('list_discount_approvals', { p_status: 'pending' });
    db.queue({ data: { status: 'approved' }, error: null });
    const decided = await decideDiscountApproval(ctx, approvalId, { approve: true, note: 'Fine' });
    expect(decided.status).toBe('approved');
    expect(db.rpc).toHaveBeenLastCalledWith('decide_discount_approval', {
      p_approval_id: approvalId,
      p_approve: true,
      p_note: 'Fine',
    });
    db.queue({ data: { status: 'rejected' }, error: null });
    await decideDiscountApproval(ctx, approvalId, { approve: false });
    expect(db.rpc).toHaveBeenLastCalledWith('decide_discount_approval', {
      p_approval_id: approvalId,
      p_approve: false,
    });
  });
});
