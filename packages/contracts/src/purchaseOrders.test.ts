import { describe, it, expect } from 'vitest';
import {
  PoOverReceiptDetail,
  PurchaseInvoiceCreateBody,
  PurchaseOrder,
  PurchaseOrderCancelBody,
  PurchaseOrderCreateBody,
  PurchaseOrderInvoiceBody,
  PurchaseOrderListQuery,
  PurchaseOrderUpdateBody,
} from './purchases.js';
import { errorCodeHttpStatus } from './errors.js';

const SUP = 'a0590000-0000-4000-8000-000000000001';
const BRANCH = 'a0590000-0000-4000-8000-000000000002';
const TV = 'a0590000-0000-4000-8000-000000000003';
const CABLE = 'a0590000-0000-4000-8000-000000000004';
const LINE = 'a0590000-0000-4000-8000-000000000005';
const PO = 'a0590000-0000-4000-8000-000000000006';

describe('U05 purchase order contracts', () => {
  const body = {
    supplier_id: SUP,
    branch_id: BRANCH,
    lines: [{ product_id: TV, quantity: 10, expected_unit_cost: '100.00' }],
  };

  it('create: each product once, quantity 1-100 000, optional cost, trimmed notes, strict', () => {
    expect(PurchaseOrderCreateBody.parse({ ...body, notes: '  Call first ' }).notes).toBe(
      'Call first',
    );
    expect(PurchaseOrderCreateBody.parse({ ...body, notes: ' ' }).notes).toBeNull();
    const noCost = { product_id: CABLE, quantity: 5 };
    expect(
      PurchaseOrderCreateBody.safeParse({ ...body, lines: [...body.lines, noCost] }).success,
    ).toBe(true);
    const twice = [body.lines[0], body.lines[0]];
    expect(PurchaseOrderCreateBody.safeParse({ ...body, lines: twice }).success).toBe(false);
    expect(PurchaseOrderCreateBody.safeParse({ ...body, lines: [] }).success).toBe(false);
    for (const line of [
      { product_id: TV, quantity: 0 },
      { product_id: TV, quantity: 100_001 },
      { product_id: TV, quantity: 1, expected_unit_cost: '-1.00' },
      { product_id: TV, quantity: 1, expected_unit_cost: '1.234' },
      { product_id: TV, quantity: 1, unit_cost: '1.00' },
    ]) {
      expect(PurchaseOrderCreateBody.safeParse({ ...body, lines: [line] }).success).toBe(false);
    }
    expect(PurchaseOrderCreateBody.safeParse({ ...body, organization_id: SUP }).success).toBe(
      false,
    );
    expect(PurchaseOrderCreateBody.safeParse({ ...body, notes: 'x'.repeat(1001) }).success).toBe(
      false,
    );
  });

  it('update needs a key; cancel needs a reason; the list query is strict', () => {
    expect(PurchaseOrderUpdateBody.safeParse({}).success).toBe(false);
    expect(PurchaseOrderUpdateBody.safeParse({ expected_date: null }).success).toBe(true);
    expect(PurchaseOrderUpdateBody.safeParse({ supplier_id: SUP }).success).toBe(false);
    expect(PurchaseOrderCancelBody.parse({ reason: '  Ordered twice ' }).reason).toBe(
      'Ordered twice',
    );
    expect(PurchaseOrderCancelBody.safeParse({ reason: 'no' }).success).toBe(false);
    expect(PurchaseOrderListQuery.parse({ status: 'sent' })).toMatchObject({ page: 1 });
    expect(PurchaseOrderListQuery.safeParse({ status: 'open' }).success).toBe(false);
    expect(PurchaseOrderListQuery.safeParse({ from: '2026-10-01' }).success).toBe(false);
  });

  it('receive: no lines, or order lines once each with a quantity and an optional cost', () => {
    expect(PurchaseOrderInvoiceBody.safeParse({}).success).toBe(true);
    const line = { po_line_id: LINE, quantity: 4 };
    expect(PurchaseOrderInvoiceBody.safeParse({ lines: [line] }).success).toBe(true);
    expect(
      PurchaseOrderInvoiceBody.safeParse({ lines: [{ ...line, unit_cost: '99.50' }] }).success,
    ).toBe(true);
    expect(PurchaseOrderInvoiceBody.safeParse({ lines: [line, line] }).success).toBe(false);
    expect(PurchaseOrderInvoiceBody.safeParse({ lines: [] }).success).toBe(false);
    expect(PurchaseOrderInvoiceBody.safeParse({ lines: [{ ...line, quantity: 0 }] }).success).toBe(
      false,
    );
  });

  it('U02 create takes an order and order lines; the order, details and error codes', () => {
    expect(
      PurchaseInvoiceCreateBody.safeParse({
        supplier_id: SUP,
        branch_id: BRANCH,
        invoice_date: '2026-10-10',
        po_id: PO,
        lines: [{ product_id: TV, quantity: 2, unit_cost: '100.00', po_line_id: LINE }],
      }).success,
    ).toBe(true);
    expect(
      PurchaseOrder.safeParse({
        id: PO,
        number: 'MAIN-PO-26-000001',
        supplier_id: SUP,
        supplier_name: 'Nile Traders',
        branch_id: BRANCH,
        status: 'partially_received',
        expected_date: null,
        notes: null,
        created_by_name: 'Owner',
        created_at: '2026-10-11T08:00:00.000Z',
        updated_at: '2026-10-11T08:00:00.000Z',
        lines: [
          {
            id: LINE,
            product_id: TV,
            name_ar: 'تلفزيون',
            name_en: null,
            sku: 'TV-55',
            is_serialized: false,
            quantity: 10,
            expected_unit_cost: null,
            received: 6,
            remaining: 4,
            on_draft_invoices: 0,
            customer_order: { order_id: SUP, number: 'MAIN-SO-26-000001', line_id: BRANCH },
          },
        ],
        invoices: [{ id: SUP, number: 'MAIN-PI-26-000001', status: 'approved', total: '684.00' }],
      }).success,
    ).toBe(true);
    expect(PoOverReceiptDetail.safeParse({ po_line_id: LINE, remaining: 4 }).success).toBe(true);
    expect(errorCodeHttpStatus.PURCHASE_ORDER_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.PURCHASE_ORDER_NOT_EDITABLE).toBe(409);
    expect(errorCodeHttpStatus.PO_NOT_SENT).toBe(409);
    expect(errorCodeHttpStatus.PO_CLOSED).toBe(409);
    expect(errorCodeHttpStatus.PO_OVER_RECEIPT).toBe(409);
    expect(errorCodeHttpStatus.PO_LINE_MISMATCH).toBe(400);
    expect(errorCodeHttpStatus.SALES_ORDER_LINE_INVALID).toBe(400);
  });
});
