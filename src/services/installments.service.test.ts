import { describe, it, expect, vi } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { getContract, postInstallmentSale } from './installments.service';

// T02: the receipt part of a sale belongs to eta.service (its own tests); here it is a stand-in.
const ETA = { status: 'pending', uuid: null, qr_payload: null, last_error_code: null };
vi.mock('./eta.service', () => ({
  withFreshEta: vi.fn((_ctx: unknown, sold: object) => Promise.resolve({ ...sold, eta: ETA })),
  withEta: vi.fn((_ctx: unknown, sold: object) => Promise.resolve({ ...sold, eta: null })),
}));

const ID = 'a0770000-0000-4000-8000-000000000001';
const BRANCH = 'a0770000-0000-4000-8000-000000000002';
const TV = 'a0770000-0000-4000-8000-000000000003';
const CUSTOMER = 'a0770000-0000-4000-8000-000000000004';
const KEY = 'n02-key-0001';
const ts = '2026-10-16T08:00:00.000Z';

const sale = {
  id: ID,
  number: 'MAIN-SL-26-000001',
  branch_id: BRANCH,
  shift_id: BRANCH,
  shift_number: 'MAIN-SH-26-000001',
  customer_id: CUSTOMER,
  customer_name: 'Good Customer',
  prices_include_vat: true,
  subtotal: '12000.00',
  discount_total: '0.00',
  discount_reason: null,
  tax_total: '1473.68',
  total: '12000.00',
  business_date: '2026-10-16',
  issued_at: ts,
  created_by_name: 'Mona',
  lines: [
    {
      id: ID,
      line_no: 1,
      warranty_until: null,
      product_id: TV,
      name_ar: 'تلفزيون',
      name_en: 'TV',
      sku: 'TV',
      is_serialized: false,
      unit_id: null,
      serial: null,
      quantity: 1,
      unit_price: '12000.00',
      tax_rate: '14.00',
      tax_amount: '1473.68',
      line_total: '12000.00',
      discount_amount: '0.00',
    },
  ],
  payments: [],
  paid_total: '2000.00',
  change_total: '0.00',
};
const contract = {
  id: ID,
  number: 'MAIN-CT-26-000001',
  status: 'active',
  branch_id: BRANCH,
  sale_id: ID,
  sale_number: 'MAIN-SL-26-000001',
  customer: { id: CUSTOMER, name: 'Good Customer', phone: '01000000001' },
  guarantors: [],
  policy_version: 2,
  creditor: 'in_house',
  cash_price: '12000.00',
  down_payment: '2000.00',
  financed_amount: '10000.00',
  markup_pct: '20',
  markup_amount: '2000.00',
  total_payable: '12000.00',
  installments_count: 1,
  frequency: 'monthly',
  first_due_date: '2026-11-16',
  last_due_date: '2026-11-16',
  current_version: 1,
  credit_approval_id: null,
  created_at: ts,
  created_by_name: 'Mona',
  lines: [
    {
      seq: 1,
      due_date: '2026-11-16',
      principal: '10000.00',
      profit: '2000.00',
      amount: '12000.00',
      paid: '0.00',
      remaining: '12000.00',
      status: 'upcoming',
    },
  ],
  balance: { paid: '0.00', remaining: '12000.00', overdue: '0.00' },
};
const body = {
  lines: [{ product_id: TV, quantity: 1 }],
  expected_total: '12000.00',
  customer_id: CUSTOMER,
  terms: {
    down_payment: '2000.00',
    installments_count: 1,
    frequency: 'monthly' as const,
    policy_version: 2,
  },
  guarantor_ids: [],
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

describe('N02 installment sale service', () => {
  it('sends the body and the key in one call and answers the sale with its receipt and the contract', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { sale, contract }, error: null });
    const answer = await postInstallmentSale(ctx, body, KEY);
    expect(db.rpc).toHaveBeenCalledWith('post_installment_sale', {
      p_body: body,
      p_idempotency_key: KEY,
    });
    expect(answer.contract.total_payable).toBe('12000.00');
    expect(answer.sale.eta).toEqual(ETA);
  });

  it('maps a business error from the database to its code', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: { message: 'CUSTOMER_NATIONAL_ID_REQUIRED', code: 'P0001', details: '', hint: '' },
    });
    await expect(postInstallmentSale(ctx, body, KEY)).rejects.toMatchObject({
      code: 'CUSTOMER_NATIONAL_ID_REQUIRED',
    });
  });

  it('refuses an answer that is not the contract shape', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { sale, contract: { ...contract, markup_pct: 'twenty' } }, error: null });
    await expect(postInstallmentSale(ctx, body, KEY)).rejects.toThrow();
  });

  it('reads a contract by id', async () => {
    const { db, ctx } = setup();
    db.queue({ data: contract, error: null });
    expect((await getContract(ctx, ID)).number).toBe('MAIN-CT-26-000001');
    expect(db.rpc).toHaveBeenCalledWith('get_contract', { p_id: ID });
  });

  it('answers CONTRACT_NOT_FOUND from the database as 404', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: { message: 'CONTRACT_NOT_FOUND', code: 'P0001', details: '', hint: '' },
    });
    await expect(getContract(ctx, ID)).rejects.toMatchObject({
      code: 'CONTRACT_NOT_FOUND',
      statusCode: 404,
    });
  });
});
