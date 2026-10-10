import { describe, it, expect } from 'vitest';
import {
  OutOfStockDetail,
  PaymentTotalMismatchDetail,
  PriceChangedDetail,
  Sale,
  SaleCreateBody,
  SaleLineInput,
  SalePaymentAccountList,
  SalePaymentInput,
  SaleQuote,
  SaleQuoteBody,
  StoreCreditDetail,
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
        paid: '500.00',
        remaining: '0.00',
        change: '0.00',
        store_credit_balance: null,
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
          tendered: null,
          change: null,
        },
      ],
      paid_total: '500.00',
      change_total: '0.00',
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

describe('S02 payment contracts', () => {
  const lines = [{ product_id: CHAIR, quantity: 2 }];
  const cash = { method: 'cash', amount: '500.00' } as const;
  const bank = {
    method: 'bank_transfer',
    amount: '500.00',
    cash_account_id: UNIT_1,
    reference: ' TRX-1 ',
  } as const;
  const credit = { method: 'store_credit', amount: '100.00' } as const;

  it('a payment line per method, strict; the reference is trimmed; card is not a method', () => {
    expect(SalePaymentInput.safeParse(cash).success).toBe(true);
    expect(SalePaymentInput.parse(bank)).toMatchObject({ reference: 'TRX-1' });
    expect(SalePaymentInput.safeParse(credit).success).toBe(true);
    expect(SalePaymentInput.safeParse({ method: 'card', amount: '1.00' }).success).toBe(false);
    for (const amount of ['0.00', '-5.00', '1.999', '']) {
      expect(SalePaymentInput.safeParse({ ...cash, amount }).success).toBe(false);
    }
    expect(SalePaymentInput.safeParse({ ...bank, reference: '   ' }).success).toBe(false);
    expect(SalePaymentInput.safeParse({ ...bank, reference: 'x'.repeat(101) }).success).toBe(false);
    expect(SalePaymentInput.safeParse({ method: 'bank_transfer', amount: '5.00' }).success).toBe(
      false,
    );
    expect(SalePaymentInput.safeParse({ ...cash, reference: 'X' }).success).toBe(false);
    expect(SalePaymentInput.safeParse({ ...credit, cash_account_id: UNIT_1 }).success).toBe(false);
  });

  it('the lines of a sale: 1-5, at most one cash, one store credit and three transfers', () => {
    const body = (payments: unknown[], customer_id?: string) => ({
      lines,
      expected_total: '500.00',
      payments,
      ...(customer_id ? { customer_id } : {}),
    });
    expect(SaleCreateBody.safeParse(body([cash, bank])).success).toBe(true);
    expect(SaleCreateBody.safeParse(body([cash, credit], PHONE)).success).toBe(true);
    expect(SaleCreateBody.safeParse(body([])).success).toBe(false);
    expect(SaleCreateBody.safeParse(body([cash, cash])).success).toBe(false);
    expect(SaleCreateBody.safeParse(body([credit, credit], PHONE)).success).toBe(false);
    expect(SaleCreateBody.safeParse(body([bank, bank, bank])).success).toBe(true);
    expect(SaleCreateBody.safeParse(body([bank, bank, bank, bank])).success).toBe(false);
    expect(
      SaleCreateBody.safeParse(body([cash, bank, bank, bank, credit, cash], PHONE)).success,
    ).toBe(false);
  });

  it('cash: handed over at least the amount; store credit needs a customer; the quote takes the same lines', () => {
    const body = (payments: unknown[]) => ({ lines, expected_total: '500.00', payments });
    expect(SaleCreateBody.safeParse(body([{ ...cash, tendered: '600.00' }])).success).toBe(true);
    expect(SaleCreateBody.safeParse(body([{ ...cash, tendered: '500.00' }])).success).toBe(true);
    expect(SaleCreateBody.safeParse(body([{ ...cash, tendered: '499.99' }])).success).toBe(false);
    expect(SaleCreateBody.safeParse(body([credit])).success).toBe(false);
    expect(SaleQuoteBody.safeParse({ lines, payments: [credit] }).success).toBe(false);
    expect(SaleQuoteBody.safeParse({ lines, payments: [credit], customer_id: PHONE }).success).toBe(
      true,
    );
    expect(SaleQuoteBody.safeParse({ lines, payments: [cash, bank] }).success).toBe(true);
    // The total check is the server's (PAYMENT_TOTAL_MISMATCH with details), not the schema's.
    expect(SaleCreateBody.safeParse(body([{ ...cash, amount: '1.00' }])).success).toBe(true);
  });

  it('the account list, the details and the new error code', () => {
    expect(SalePaymentAccountList.safeParse({ items: [{ id: UNIT_1, name: 'NBE' }] }).success).toBe(
      true,
    );
    expect(
      SalePaymentAccountList.safeParse({ items: [{ id: UNIT_1, name: 'NBE', balance: '1.00' }] })
        .success,
    ).toBe(true);
    expect(PaymentTotalMismatchDetail.safeParse({ total: '1000.00', paid: '999.99' }).success).toBe(
      true,
    );
    expect(StoreCreditDetail.safeParse({ balance: '300.00' }).success).toBe(true);
    expect(errorCodeHttpStatus.PAYMENT_TOTAL_MISMATCH).toBe(400);
    expect(errorCodeHttpStatus.INSUFFICIENT_STORE_CREDIT).toBe(409);
  });
});
