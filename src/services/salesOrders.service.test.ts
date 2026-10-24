import { describe, it, expect } from 'vitest';
import {
  CancelSalesOrderBody,
  CreateSalesOrderBody,
  OrderDepositBody,
  OrderFromQuotationBody,
  SalesOrderListQuery,
} from '@ziadkhaled-wb/contracts';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import * as so from './salesOrders.service';
const ID = 'a7100000-0000-4000-8000-000000000001';
const LINE = 'a7100000-0000-4000-8000-000000000002';
const OTHER_LINE = 'a7100000-0000-4000-8000-000000000003';
const PO_LINE = 'a7100000-0000-4000-8000-000000000004';
const AT = '2026-10-23T10:00:00.000Z';
function fixture() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    db: db as unknown as DbClient,
    orgId: ID,
    employeeId: ID,
    role: 'OWNER',
    userId: ID,
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
  };
  return { db, ctx };
}
function line(id: string) {
  return {
    id,
    order_id: ID,
    line_no: 1,
    product_id: ID,
    custom_notes: null,
    quantity: 1,
    unit_price: '100.00',
    discount_amount: '0.00',
    tax_class_id: ID,
    tax_rate: '14.00',
    tax_amount: '14.00',
    line_total: '114.00',
    fulfilment: 'to_order',
    po_line_id: null,
    created_at: AT,
    created_by: ID,
    product: { id: ID, sku: 'SKU-1', name_ar: 'كنبة', name_en: 'Sofa', is_serialized: false },
    delivered: 0,
    reserved: 0,
    remaining: 1,
    purchase_order: null,
    reserved_units: [],
  };
}
function salesOrder(lineIds: string[] = [LINE]) {
  return {
    id: ID,
    number: 'BR1-SO-26-000001',
    customer_id: ID,
    branch_id: ID,
    quotation_id: null,
    status: 'open',
    prices_include_vat: false,
    subtotal: '100.00',
    discount_total: '0.00',
    tax_total: '14.00',
    total: '114.00',
    delivery_address: null,
    notes: null,
    cancelled_reason: null,
    created_at: AT,
    created_by: ID,
    updated_at: AT,
    updated_by: ID,
    customer: { id: ID, name: 'Customer', phone: null },
    branch: { id: ID, name: 'Branch', address: null },
    quotation: null,
    lines: lineIds.map(line),
    payments: [],
    balances: {
      deposits_paid: '0.00',
      financed: '0.00',
      delivered_value: '0.00',
      unpaid: '114.00',
    },
  };
}
describe('S10 sales orders service', () => {
  it('maps list filters and paging to the RPC arguments', async () => {
    const { db, ctx } = fixture();
    db.queue({ data: { items: [], total: 0 }, error: null });
    await so.list(
      ctx,
      SalesOrderListQuery.parse({
        status: 'open',
        branch_id: ID,
        customer_id: ID,
        from: '2026-10-01',
        to: '2026-10-31',
        search: 'SO-26',
        page: 3,
        page_size: 10,
      }),
    );
    expect(db.rpc).toHaveBeenCalledWith('list_sales_orders', {
      p_status: 'open',
      p_branch_id: ID,
      p_customer_id: ID,
      p_from: '2026-10-01',
      p_to: '2026-10-31',
      p_search: 'SO-26',
      p_limit: 10,
      p_offset: 20,
    });
  });
  it('sends only priced input and the idempotency key on create, never a client total', async () => {
    const { db, ctx } = fixture();
    db.queue({ data: salesOrder(), error: null });
    const body = CreateSalesOrderBody.parse({
      branch_id: ID,
      customer_id: ID,
      total: '999',
      lines: [{ product_id: ID, quantity: 1, unit_price: '100.00', line_total: '999' }],
    });
    await so.create(ctx, body, 's10-create-key');
    expect(db.rpc).toHaveBeenCalledWith('create_sales_order', {
      p_branch_id: ID,
      p_customer_id: ID,
      p_delivery_address: null,
      p_notes: null,
      p_lines: [
        {
          product_id: ID,
          quantity: 1,
          unit_price: '100.00',
          discount_amount: '0',
          fulfilment: 'from_stock',
        },
      ],
      p_idempotency_key: 's10-create-key',
    });
  });
  it('passes the quotation id, line options and idempotency key when ordering a quotation', async () => {
    const { db, ctx } = fixture();
    db.queue({ data: salesOrder(), error: null });
    const body = OrderFromQuotationBody.parse({
      delivery_address: 'Cairo',
      line_options: { '1': { fulfilment: 'to_order', po_line_id: PO_LINE } },
    });
    await so.fromQuotation(ctx, ID, body, 's10-quote-key');
    expect(db.rpc).toHaveBeenCalledWith('create_order_from_quotation', {
      p_quotation_id: ID,
      p_delivery_address: 'Cairo',
      p_line_options: { '1': { fulfilment: 'to_order', po_line_id: PO_LINE } },
      p_idempotency_key: 's10-quote-key',
    });
  });
  it('passes the idempotency key through on deposit and cancel', async () => {
    const { db, ctx } = fixture();
    db.queue({ data: salesOrder(), error: null }, { data: salesOrder(), error: null });
    await so.deposit(
      ctx,
      ID,
      OrderDepositBody.parse({ payments: [{ method: 'cash', amount: '50.00' }] }),
      's10-deposit-key',
    );
    await so.cancel(
      ctx,
      ID,
      CancelSalesOrderBody.parse({ reason: 'changed mind' }),
      's10-cancel-key',
    );
    expect(db.rpc).toHaveBeenNthCalledWith(
      1,
      'record_order_deposit',
      expect.objectContaining({ p_order_id: ID, p_idempotency_key: 's10-deposit-key' }),
    );
    expect(db.rpc).toHaveBeenNthCalledWith(2, 'cancel_sales_order', {
      p_order_id: ID,
      p_reason: 'changed mind',
      p_refund: [],
      p_idempotency_key: 's10-cancel-key',
    });
  });
  it('reserves and links a line that belongs to the order by its line id', async () => {
    const { db, ctx } = fixture();
    db.queue(
      { data: salesOrder(), error: null },
      { data: salesOrder(), error: null },
      { data: salesOrder(), error: null },
      { data: salesOrder(), error: null },
    );
    await so.reserve(ctx, ID, LINE, undefined);
    await so.linkPo(ctx, ID, LINE, PO_LINE);
    expect(db.rpc).toHaveBeenNthCalledWith(1, 'get_sales_order', { p_id: ID });
    expect(db.rpc).toHaveBeenNthCalledWith(2, 'reserve_order_line', {
      p_order_line_id: LINE,
      p_unit_ids: null,
    });
    expect(db.rpc).toHaveBeenNthCalledWith(4, 'link_order_line_to_po', {
      p_order_line_id: LINE,
      p_po_line_id: PO_LINE,
    });
  });
  for (const run of [
    (ctx: RequestContext) => so.reserve(ctx, ID, OTHER_LINE, undefined),
    (ctx: RequestContext) => so.linkPo(ctx, ID, OTHER_LINE, PO_LINE),
  ])
    it('returns ORDER_NOT_FOUND 404 for a line not on the order, without calling the line RPC', async () => {
      const { db, ctx } = fixture();
      db.queue({ data: salesOrder([LINE]), error: null });
      await expect(run(ctx)).rejects.toMatchObject({ code: 'ORDER_NOT_FOUND', statusCode: 404 });
      expect(db.rpc).toHaveBeenCalledTimes(1);
    });
  it('maps the database PO_NOT_FOUND to PURCHASE_ORDER_NOT_FOUND 404', async () => {
    const { db, ctx } = fixture();
    db.queue(
      { data: salesOrder(), error: null },
      { data: null, error: { message: 'PO_NOT_FOUND' } },
    );
    await expect(so.linkPo(ctx, ID, LINE, PO_LINE)).rejects.toMatchObject({
      code: 'PURCHASE_ORDER_NOT_FOUND',
      statusCode: 404,
    });
  });
  for (const [code, status] of [
    ['ORDER_NOT_FOUND', 404],
    ['ORDER_NOT_OPEN', 409],
    ['QUOTATION_ALREADY_ORDERED', 409],
    ['PO_LINE_OVERCOMMITTED', 409],
    ['ORDER_LINES_INVALID', 422],
    ['UNITS_REQUIRED', 422],
  ] as const)
    it('maps ' + code, async () => {
      const { db, ctx } = fixture();
      db.queue({ data: null, error: { message: code } });
      await expect(so.get(ctx, ID)).rejects.toMatchObject({ code, statusCode: status });
    });
});
