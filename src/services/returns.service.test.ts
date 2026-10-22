import { describe, it, expect } from 'vitest';
import { SalesReturnCreateBody, SalesReturnListQuery } from '@ziadkhaled-wb/contracts';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import * as returns from './returns.service';

const ID = 'a0500000-0000-4000-8000-000000000001';
const LINE = 'a0500000-0000-4000-8000-000000000002';
function fixture() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    db: db as unknown as DbClient,
    orgId: ID,
    employeeId: ID,
    role: 'BRANCH_MANAGER',
    userId: ID,
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
  };
  return { db, ctx };
}

const stored = {
  id: ID,
  number: 'MAIN-RT-26-000001',
  kind: 'return',
  refund_method: 'cash',
  sale: { id: ID, number: 'MAIN-SL-26-000001', business_date: '2026-10-22', total: '1000.00' },
  branch: { id: ID, name: 'Main' },
  customer: null,
  shift_id: ID,
  subtotal: '219.30',
  tax_total: '30.70',
  total: '250.00',
  reason: 'Customer changed his mind',
  business_date: '2026-10-22',
  created_at: '2026-10-22T10:00:00+00:00',
  created_by: { id: ID, name: 'Manager' },
  lines: [
    {
      id: ID,
      sale_line_id: LINE,
      line_no: 1,
      product_id: ID,
      sku: 'CH',
      name_ar: 'كرسي',
      name_en: 'Chair',
      unit_id: null,
      serial: null,
      quantity: 1,
      condition: 'resellable',
      refund_amount: '250.00',
      tax_amount: '30.70',
      tax_rate: '14.00',
    },
  ],
  refunds: [
    {
      id: ID,
      number: 'MAIN-PY-26-000002',
      method: 'cash',
      amount: '250.00',
      cash_account_id: ID,
      cash_account_name: 'Drawer',
      reference: null,
      exchange: false,
    },
  ],
  contract_change: null,
  exchange_sale: null,
  fiscal: null,
  receipt_prints: 0,
};

const body = SalesReturnCreateBody.parse({
  sale_id: ID,
  lines: [{ sale_line_id: LINE, quantity: 1 }],
  refunds: [{ method: 'cash', amount: '250.00' }],
  reason: 'Customer changed his mind',
  expected_total: '250.00',
});

describe('S05 returns service', () => {
  it('posts the body and the key as they are; the rules are in SQL', async () => {
    const { ctx, db } = fixture();
    db.queue({ data: stored, error: null });
    const result = await returns.post(ctx, body, 'return-key-1');
    expect(result.number).toBe('MAIN-RT-26-000001');
    expect(db.rpc).toHaveBeenCalledWith('post_sales_return', {
      p_body: body,
      p_idempotency_key: 'return-key-1',
    });
    expect(body.lines[0]!.condition).toBe('resellable');
    expect(body.kind).toBe('return');
  });

  it.each([
    ['RETURN_QTY_EXCEEDED: x can take 3 more', 'RETURN_QTY_EXCEEDED', 409],
    ['RETURN_UNIT_MISMATCH: this unit was not sold on the line', 'RETURN_UNIT_MISMATCH', 409],
    ['RETURN_PERIOD_EXPIRED: the period ended on 2026-10-16', 'RETURN_PERIOD_EXPIRED', 409],
    ['RETURN_OTHER_BRANCH: the sale belongs to another branch', 'RETURN_OTHER_BRANCH', 409],
    ['REFUND_EXCEEDS_PAID: cash refunds more than the sale took', 'REFUND_EXCEEDS_PAID', 409],
    ['EXCHANGE_NOT_FOR_CONTRACT: return it, then sell again', 'EXCHANGE_NOT_FOR_CONTRACT', 409],
    ['RETURN_ETA_WINDOW_PASSED: older than 540 days', 'RETURN_ETA_WINDOW_PASSED', 409],
    ['SALE_NOT_FOUND', 'SALE_NOT_FOUND', 404],
  ] as const)('maps %s', async (message, code, status) => {
    const { ctx, db } = fixture();
    db.queue({ data: null, error: { message } });
    await expect(returns.post(ctx, body, 'return-key-2')).rejects.toMatchObject({
      code,
      statusCode: status,
    });
  });

  it('a replay is parsed with its flag', async () => {
    const { ctx, db } = fixture();
    db.queue({ data: { ...stored, replayed: true }, error: null });
    expect((await returns.post(ctx, body, 'return-key-1')).replayed).toBe(true);
  });

  it('lists with the parsed filters and reads one (RETURN_NOT_FOUND is 404)', async () => {
    const { ctx, db } = fixture();
    const query = SalesReturnListQuery.parse({ kind: 'exchange', page: '2' });
    db.queue({ data: { items: [], total_count: 0, page: 2, page_size: 20 }, error: null });
    expect((await returns.list(ctx, query)).page).toBe(2);
    expect(db.rpc).toHaveBeenCalledWith('list_sales_returns', { p_filters: query });
    db.queue({ data: null, error: { message: 'RETURN_NOT_FOUND' } });
    await expect(returns.get(ctx, ID)).rejects.toMatchObject({
      code: 'RETURN_NOT_FOUND',
      statusCode: 404,
    });
  });

  it('logs a print: the first is the original', async () => {
    const { ctx, db } = fixture();
    db.queue({ data: { print_no: 1, copy: false }, error: null });
    expect(await returns.recordReceiptPrint(ctx, ID)).toEqual({ print_no: 1, copy: false });
    expect(db.rpc).toHaveBeenCalledWith('record_return_receipt_print', { p_id: ID });
  });
});
