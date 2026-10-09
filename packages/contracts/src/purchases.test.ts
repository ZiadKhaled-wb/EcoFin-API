import { describe, it, expect } from 'vitest';
import {
  PurchaseInvoice,
  PurchaseInvoiceCreateBody,
  PurchaseInvoiceList,
  PurchaseInvoiceListQuery,
  PurchaseInvoiceRejectBody,
  PurchaseInvoiceUpdateBody,
  SerialsRequiredDetail,
} from './purchases.js';
import { errorCodeHttpStatus } from './errors.js';

const SUPPLIER = 'a0540000-0000-4000-8000-000000000001';
const BRANCH = 'a0540000-0000-4000-8000-000000000002';
const TV = 'a0540000-0000-4000-8000-000000000003';
const PHONE = 'a0540000-0000-4000-8000-000000000004';
const CLASS = 'a0540000-0000-4000-8000-000000000005';
const ts = '2026-10-11T08:00:00.000Z';

const body = {
  supplier_id: SUPPLIER,
  branch_id: BRANCH,
  supplier_invoice_no: ' S-100 ',
  invoice_date: '2026-10-10',
  lines: [
    { product_id: TV, quantity: 10, unit_cost: '130.00' },
    {
      product_id: PHONE,
      quantity: 2,
      unit_cost: '900',
      tax_class_id: CLASS,
      serials: [' sn-1', 'SN-2 '],
    },
  ],
};

const line = {
  id: 'a0540000-0000-4000-8000-000000000010',
  product_id: TV,
  name_ar: 'تلفزيون',
  name_en: null,
  sku: 'TV-55',
  is_serialized: false,
  quantity: 10,
  unit_cost: '130.00',
  tax_class_id: CLASS,
  tax_rate: '14.00',
  tax_amount: '182.00',
  net: '1300.00',
  line_total: '1482.00',
  serials: null,
  unit_ids: [],
};
const invoice = {
  id: 'a0540000-0000-4000-8000-000000000020',
  number: 'BR1-PI-26-000001',
  supplier_id: SUPPLIER,
  supplier_name: 'Nile Traders',
  branch_id: BRANCH,
  supplier_invoice_no: 'S-100',
  invoice_date: '2026-10-10',
  status: 'draft',
  subtotal: '1300.00',
  tax_total: '182.00',
  total: '1482.00',
  outstanding: null,
  approved_by_name: null,
  approved_at: null,
  rejected_reason: null,
  created_by_name: 'Owner',
  created_at: ts,
  updated_at: ts,
};

describe('U02 purchase invoice contracts', () => {
  it('create: trims the supplier invoice no and upper-cases serials', () => {
    const parsed = PurchaseInvoiceCreateBody.parse(body);
    expect(parsed.supplier_invoice_no).toBe('S-100');
    expect(parsed.lines[1]!.serials).toEqual(['SN-1', 'SN-2']);
    expect(
      PurchaseInvoiceCreateBody.parse({ ...body, supplier_invoice_no: '' }).supplier_invoice_no,
    ).toBeNull();
    const { supplier_invoice_no: _omitted, ...withoutNo } = body;
    expect(PurchaseInvoiceCreateBody.parse(withoutNo)).not.toHaveProperty('supplier_invoice_no');
  });

  it('create: refuses bad lines', () => {
    const bad = [
      { ...body, lines: [] },
      { ...body, lines: [body.lines[0], body.lines[0]] },
      { ...body, lines: [{ ...body.lines[0], quantity: 0 }] },
      { ...body, lines: [{ ...body.lines[0], quantity: 100_001 }] },
      { ...body, lines: [{ ...body.lines[0], quantity: 1.5 }] },
      { ...body, lines: [{ ...body.lines[0], unit_cost: '-1.00' }] },
      { ...body, lines: [{ ...body.lines[0], unit_cost: '1.234' }] },
      { ...body, lines: [{ ...body.lines[0], unit_cost: 130 }] },
      { ...body, lines: [{ ...body.lines[1], serials: ['SN-1'] }] },
      { ...body, lines: [{ ...body.lines[1], serials: ['!bad', 'SN-2'] }] },
      { ...body, lines: [{ ...body.lines[0], discount: '1' }] },
      { ...body, lines: Array.from({ length: 201 }, () => body.lines[0]) },
      { ...body, invoice_date: '2026-02-30' },
      { ...body, supplier_invoice_no: 'x'.repeat(41) },
      { ...body, organization_id: SUPPLIER },
      { ...body, status: 'approved' },
    ];
    for (const b of bad) {
      expect(PurchaseInvoiceCreateBody.safeParse(b).success, JSON.stringify(b).slice(0, 120)).toBe(
        false,
      );
    }
  });

  it('update: at least one key, supplier and branch fixed', () => {
    expect(PurchaseInvoiceUpdateBody.safeParse({}).success).toBe(false);
    expect(PurchaseInvoiceUpdateBody.safeParse({ supplier_id: SUPPLIER }).success).toBe(false);
    expect(PurchaseInvoiceUpdateBody.safeParse({ branch_id: BRANCH }).success).toBe(false);
    expect(PurchaseInvoiceUpdateBody.parse({ supplier_invoice_no: null })).toEqual({
      supplier_invoice_no: null,
    });
    expect(PurchaseInvoiceUpdateBody.parse({ lines: [body.lines[0]] }).lines).toHaveLength(1);
  });

  it('reject: a trimmed reason of 3-500 characters', () => {
    expect(PurchaseInvoiceRejectBody.parse({ reason: '  Wrong prices ' })).toEqual({
      reason: 'Wrong prices',
    });
    expect(PurchaseInvoiceRejectBody.safeParse({ reason: ' ab ' }).success).toBe(false);
    expect(PurchaseInvoiceRejectBody.safeParse({ reason: 'x'.repeat(501) }).success).toBe(false);
  });

  it('the invoice and the list shapes keep money as strings', () => {
    expect(PurchaseInvoice.parse({ ...invoice, lines: [line] }).lines[0]!.line_total).toBe(
      '1482.00',
    );
    expect(PurchaseInvoice.safeParse({ ...invoice, total: 1482, lines: [] }).success).toBe(false);
    expect(
      PurchaseInvoiceList.parse({
        items: [{ ...invoice, status: 'approved', outstanding: '1482.00', lines_count: 1 }],
        page: 1,
        pageSize: 50,
        total: 1,
      }).items[0]!.outstanding,
    ).toBe('1482.00');
  });

  it('list query: filters, trimmed search, dates in order, strict', () => {
    expect(PurchaseInvoiceListQuery.parse({ status: 'draft', search: ' s-1 ', page: '2' })).toEqual(
      {
        status: 'draft',
        search: 's-1',
        page: 2,
        pageSize: 50,
      },
    );
    expect(
      PurchaseInvoiceListQuery.safeParse({ from: '2026-10-02', to: '2026-10-01' }).success,
    ).toBe(false);
    expect(PurchaseInvoiceListQuery.safeParse({ status: 'paid' }).success).toBe(false);
    expect(PurchaseInvoiceListQuery.safeParse({ organization_id: SUPPLIER }).success).toBe(false);
  });

  it('error codes and the SERIALS_REQUIRED detail', () => {
    expect(errorCodeHttpStatus.PURCHASE_INVOICE_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.PURCHASE_INVOICE_NOT_EDITABLE).toBe(409);
    expect(errorCodeHttpStatus.SUPPLIER_INVOICE_NO_TAKEN).toBe(409);
    expect(errorCodeHttpStatus.SUPPLIER_ARCHIVED).toBe(409);
    expect(errorCodeHttpStatus.SERIALS_REQUIRED).toBe(422);
    expect(SerialsRequiredDetail.parse({ line_ids: [TV] }).line_ids).toEqual([TV]);
    expect(SerialsRequiredDetail.safeParse({ line_ids: ['x'] }).success).toBe(false);
  });
});
