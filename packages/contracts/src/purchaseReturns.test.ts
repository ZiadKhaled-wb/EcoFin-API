import { describe, it, expect } from 'vitest';
import {
  PayableCashAccountList,
  PayableCashAccountQuery,
  PurchaseReturn,
  PurchaseReturnCreateBody,
  PurchaseReturnListQuery,
  ReturnQtyExceededDetail,
} from './purchases.js';
import { errorCodeHttpStatus } from './errors.js';

const INV = 'a0570000-0000-4000-8000-000000000001';
const LINE = 'a0570000-0000-4000-8000-000000000002';
const UNIT = 'a0570000-0000-4000-8000-000000000003';
const SAFE = 'a0570000-0000-4000-8000-000000000004';

describe('U04 purchase return contracts', () => {
  const body = {
    purchase_invoice_id: INV,
    refund_mode: 'supplier_credit',
    reason: '  Damaged ',
    lines: [{ invoice_line_id: LINE, quantity: 4 }],
  };

  it('create: trims the reason; each line has quantity or unit_ids, once', () => {
    expect(PurchaseReturnCreateBody.parse(body).reason).toBe('Damaged');
    const both = { invoice_line_id: LINE, quantity: 1, unit_ids: [UNIT] };
    expect(PurchaseReturnCreateBody.safeParse({ ...body, lines: [both] }).success).toBe(false);
    expect(
      PurchaseReturnCreateBody.safeParse({ ...body, lines: [{ invoice_line_id: LINE }] }).success,
    ).toBe(false);
    const units = { invoice_line_id: LINE, unit_ids: [UNIT, UNIT] };
    expect(PurchaseReturnCreateBody.safeParse({ ...body, lines: [units] }).success).toBe(false);
    const twice = [body.lines[0], body.lines[0]];
    expect(PurchaseReturnCreateBody.safeParse({ ...body, lines: twice }).success).toBe(false);
    expect(PurchaseReturnCreateBody.safeParse({ ...body, lines: [] }).success).toBe(false);
    expect(PurchaseReturnCreateBody.safeParse({ ...body, reason: 'ab' }).success).toBe(false);
    expect(
      PurchaseReturnCreateBody.safeParse({
        ...body,
        lines: [{ invoice_line_id: LINE, quantity: 0 }],
      }).success,
    ).toBe(false);
  });

  it('create: cash needs an account, credit takes none', () => {
    expect(PurchaseReturnCreateBody.safeParse({ ...body, refund_mode: 'cash' }).success).toBe(
      false,
    );
    expect(
      PurchaseReturnCreateBody.safeParse({ ...body, refund_mode: 'cash', cash_account_id: SAFE })
        .success,
    ).toBe(true);
    expect(PurchaseReturnCreateBody.safeParse({ ...body, cash_account_id: SAFE }).success).toBe(
      false,
    );
  });

  it('the return, the list query, the accounts and the detail', () => {
    const ret = {
      id: INV,
      number: 'MAIN-PR-26-000001',
      purchase_invoice_id: INV,
      invoice_number: 'MAIN-PI-26-000001',
      supplier_id: INV,
      supplier_name: 'Nile',
      branch_id: INV,
      refund_mode: 'cash',
      cash_account_id: SAFE,
      cash_account_name: 'Main safe',
      subtotal: '400.00',
      tax_total: '56.00',
      total: '456.00',
      reason: 'Damaged',
      business_date: '2026-10-11',
      created_by_name: 'Owner',
      created_at: '2026-10-11T08:00:00.000Z',
      lines: [
        {
          id: LINE,
          invoice_line_id: LINE,
          product_id: INV,
          name_ar: 'تلفزيون',
          name_en: null,
          sku: 'TV',
          unit_id: null,
          serial: null,
          quantity: 4,
          unit_cost: '100.00',
          tax_amount: '56.00',
          net: '400.00',
          line_total: '456.00',
        },
      ],
    };
    expect(PurchaseReturn.parse(ret)).toEqual(ret);
    expect(
      PurchaseReturnListQuery.safeParse({ from: '2026-10-12', to: '2026-10-11' }).success,
    ).toBe(false);
    expect(PurchaseReturnListQuery.safeParse({ organization_id: INV }).success).toBe(false);
    expect(
      PayableCashAccountList.parse({
        items: [{ id: SAFE, name: 'Main safe', kind: 'safe', branch_id: null, balance: '10.00' }],
      }).items,
    ).toHaveLength(1);
    expect(PayableCashAccountQuery.safeParse({}).success).toBe(false);
    expect(ReturnQtyExceededDetail.parse({ invoice_line_id: LINE, returnable: 0 }).returnable).toBe(
      0,
    );
    expect(errorCodeHttpStatus.PURCHASE_RETURN_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.PURCHASE_INVOICE_NOT_APPROVED).toBe(409);
    expect(errorCodeHttpStatus.RETURN_QTY_EXCEEDED).toBe(409);
  });
});
