import { describe, it, expect } from 'vitest';
import {
  OutOfStockDetail,
  PriceChangedDetail,
  Sale,
  SaleCreateBody,
  SaleLineInput,
  SaleQuote,
  SaleQuoteBody,
} from './sales.js';
import { errorCodeHttpStatus } from './errors.js';

const CHAIR = 'a0620000-0000-4000-8000-000000000001';
const PHONE = 'a0620000-0000-4000-8000-000000000002';
const UNIT_1 = 'a0620000-0000-4000-8000-000000000003';
const UNIT_2 = 'a0620000-0000-4000-8000-000000000004';
const ts = '2026-10-12T08:00:00.000Z';

describe('S01 sale contracts', () => {
  it('a line: a product and a whole quantity; a unit is sold one at a time; strict', () => {
    expect(SaleLineInput.safeParse({ product_id: CHAIR, quantity: 2 }).success).toBe(true);
    expect(
      SaleLineInput.safeParse({ product_id: PHONE, quantity: 1, unit_id: UNIT_1 }).success,
    ).toBe(true);
    expect(
      SaleLineInput.safeParse({ product_id: PHONE, quantity: 2, unit_id: UNIT_1 }).success,
    ).toBe(false);
    for (const quantity of [0, -1, 1.5, 100_001]) {
      expect(SaleLineInput.safeParse({ product_id: CHAIR, quantity }).success).toBe(false);
    }
    for (const unit_price of ['-1.00', '1.999', 'abc']) {
      expect(SaleLineInput.safeParse({ product_id: CHAIR, quantity: 1, unit_price }).success).toBe(
        false,
      );
    }
    expect(
      SaleLineInput.safeParse({ product_id: CHAIR, quantity: 1, unit_price: '200.00' }).success,
    ).toBe(true);
    expect(
      SaleLineInput.safeParse({ product_id: CHAIR, quantity: 1, organization_id: CHAIR }).success,
    ).toBe(false);
  });

  it('a cart: 1-100 lines, a unit once, a product on one line unless every line has a unit', () => {
    const chair = { product_id: CHAIR, quantity: 1 };
    const phone = (unit_id: string) => ({ product_id: PHONE, quantity: 1, unit_id });
    expect(SaleQuoteBody.safeParse({ lines: [] }).success).toBe(false);
    expect(SaleQuoteBody.safeParse({ lines: [chair, phone(UNIT_1), phone(UNIT_2)] }).success).toBe(
      true,
    );
    expect(SaleQuoteBody.safeParse({ lines: [chair, chair] }).success).toBe(false);
    expect(SaleQuoteBody.safeParse({ lines: [phone(UNIT_1), phone(UNIT_1)] }).success).toBe(false);
    expect(
      SaleQuoteBody.safeParse({ lines: [phone(UNIT_1), { product_id: PHONE, quantity: 1 }] })
        .success,
    ).toBe(false);
    expect(
      SaleQuoteBody.safeParse({ lines: Array.from({ length: 101 }, () => chair) }).success,
    ).toBe(false);
    expect(SaleQuoteBody.safeParse({ lines: [chair], branch_id: CHAIR }).success).toBe(false);
  });

  it('create: the total the cashier saw is required; no branch, no prices from the client', () => {
    const lines = [{ product_id: CHAIR, quantity: 2 }];
    expect(SaleCreateBody.safeParse({ lines, expected_total: '500.00' }).success).toBe(true);
    expect(
      SaleCreateBody.safeParse({ lines, expected_total: '500.00', customer_id: PHONE }).success,
    ).toBe(true);
    expect(SaleCreateBody.safeParse({ lines }).success).toBe(false);
    expect(SaleCreateBody.safeParse({ lines, expected_total: '-500.00' }).success).toBe(false);
    expect(
      SaleCreateBody.safeParse({ lines, expected_total: '500.00', total: '1.00' }).success,
    ).toBe(false);
    expect(
      SaleCreateBody.safeParse({ lines, expected_total: '500.00', organization_id: CHAIR }).success,
    ).toBe(false);
  });

  it('the quote, the sale, the details and the error codes', () => {
    const line = {
      product_id: CHAIR,
      name_ar: 'كرسي',
      name_en: 'Chair',
      sku: 'CH',
      is_serialized: false,
      unit_id: null,
      serial: null,
      quantity: 2,
      unit_price: '250.00',
      tax_rate: '14.00',
      tax_amount: '61.40',
      line_total: '500.00',
    };
    expect(
      SaleQuote.safeParse({
        prices_include_vat: true,
        lines: [{ ...line, list_price: '250.00', overridden: false, available: 10 }],
        subtotal: '500.00',
        tax_total: '61.40',
        total: '500.00',
      }).success,
    ).toBe(true);
    const sale = {
      id: UNIT_1,
      number: 'MAIN-SL-26-000001',
      branch_id: PHONE,
      shift_id: UNIT_2,
      shift_number: 'MAIN-SH-26-000001',
      customer_id: null,
      customer_name: null,
      prices_include_vat: true,
      subtotal: '500.00',
      discount_total: '0.00',
      tax_total: '61.40',
      total: '500.00',
      business_date: '2026-10-12',
      issued_at: ts,
      created_by_name: 'Mona',
      lines: [{ ...line, id: UNIT_2, line_no: 1, warranty_until: null }],
      payments: [
        {
          id: UNIT_2,
          number: 'MAIN-PY-26-000001',
          method: 'cash',
          amount: '500.00',
          cash_account_id: CHAIR,
          cash_account_name: 'Drawer',
          reference: null,
        },
      ],
    };
    expect(Sale.safeParse(sale).success).toBe(true);
    expect(
      Sale.safeParse({ ...sale, payments: [{ ...sale.payments[0], method: 'card' }] }).success,
    ).toBe(false);
    expect(
      PriceChangedDetail.safeParse({ expected_total: '240.00', total: '250.00' }).success,
    ).toBe(true);
    expect(
      OutOfStockDetail.safeParse({ product_id: CHAIR, requested: 3, available: 1 }).success,
    ).toBe(true);
    expect(errorCodeHttpStatus.SALE_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.CUSTOMER_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.PRODUCT_ARCHIVED).toBe(409);
    expect(errorCodeHttpStatus.PRICE_CHANGED).toBe(409);
    expect(errorCodeHttpStatus.PRICE_OVERRIDE_DENIED).toBe(403);
  });
});
