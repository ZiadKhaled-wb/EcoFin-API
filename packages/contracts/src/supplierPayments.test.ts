import { describe, it, expect } from 'vitest';
import {
  OpenSupplierInvoiceList,
  PaymentExceedsOutstandingDetail,
  SupplierPayment,
  SupplierPaymentCreateBody,
  SupplierPaymentListQuery,
  SupplierPaymentReverseBody,
} from './supplierPayments.js';
import { errorCodeHttpStatus } from './errors.js';

const SUP = 'a0580000-0000-4000-8000-000000000001';
const BRANCH = 'a0580000-0000-4000-8000-000000000002';
const SAFE = 'a0580000-0000-4000-8000-000000000003';
const INV_A = 'a0580000-0000-4000-8000-000000000004';
const INV_B = 'a0580000-0000-4000-8000-000000000005';

describe('U03 supplier payment contracts', () => {
  const body = { supplier_id: SUP, branch_id: BRANCH, cash_account_id: SAFE, amount: '3000.00' };

  it('create: amount above 0, two decimals, trimmed reference, strict', () => {
    expect(SupplierPaymentCreateBody.parse({ ...body, reference: ' TRX-1 ' }).reference).toBe(
      'TRX-1',
    );
    expect(SupplierPaymentCreateBody.safeParse({ ...body, reference: null }).success).toBe(true);
    for (const amount of ['0', '0.00', '-1.00', '1.234', 'abc']) {
      expect(SupplierPaymentCreateBody.safeParse({ ...body, amount }).success).toBe(false);
    }
    expect(SupplierPaymentCreateBody.safeParse({ ...body, organization_id: SUP }).success).toBe(
      false,
    );
    expect(
      SupplierPaymentCreateBody.safeParse({ ...body, reference: 'x'.repeat(101) }).success,
    ).toBe(false);
  });

  it('create: allocations add up to the amount, each invoice once', () => {
    const ok = [
      { purchase_invoice_id: INV_A, amount: '2000.00' },
      { purchase_invoice_id: INV_B, amount: '1000' },
    ];
    expect(SupplierPaymentCreateBody.safeParse({ ...body, allocations: ok }).success).toBe(true);
    expect(SupplierPaymentCreateBody.safeParse({ ...body, allocations: [ok[0]] }).success).toBe(
      false,
    );
    const twice = [
      { purchase_invoice_id: INV_A, amount: '1500.00' },
      { purchase_invoice_id: INV_A, amount: '1500.00' },
    ];
    expect(SupplierPaymentCreateBody.safeParse({ ...body, allocations: twice }).success).toBe(
      false,
    );
    expect(SupplierPaymentCreateBody.safeParse({ ...body, allocations: [] }).success).toBe(false);
    const zero = [
      { purchase_invoice_id: INV_A, amount: '3000.00' },
      { purchase_invoice_id: INV_B, amount: '0.00' },
    ];
    expect(SupplierPaymentCreateBody.safeParse({ ...body, allocations: zero }).success).toBe(false);
  });

  it('reverse: a reason of 3 to 500 characters', () => {
    expect(SupplierPaymentReverseBody.parse({ reason: '  Wrong supplier ' }).reason).toBe(
      'Wrong supplier',
    );
    expect(SupplierPaymentReverseBody.safeParse({ reason: 'no' }).success).toBe(false);
    expect(SupplierPaymentReverseBody.safeParse({ reason: 'x'.repeat(501) }).success).toBe(false);
  });

  it('list query: reversals included by default; date order; strict', () => {
    expect(SupplierPaymentListQuery.parse({})).toMatchObject({
      include_reversals: true,
      page: 1,
    });
    expect(SupplierPaymentListQuery.parse({ include_reversals: 'false' }).include_reversals).toBe(
      false,
    );
    expect(
      SupplierPaymentListQuery.safeParse({ from: '2026-10-02', to: '2026-10-01' }).success,
    ).toBe(false);
    expect(SupplierPaymentListQuery.safeParse({ status: 'x' }).success).toBe(false);
  });

  it('payment, open invoices, details and the error codes', () => {
    const payment = {
      id: INV_A,
      number: 'MAIN-SP-26-000001',
      supplier_id: SUP,
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
      allocations: [{ purchase_invoice_id: INV_A, invoice_number: 'PI-1', amount: '3000.00' }],
    };
    expect(SupplierPayment.safeParse(payment).success).toBe(true);
    expect(
      OpenSupplierInvoiceList.safeParse({
        items: [
          {
            purchase_invoice_id: INV_A,
            number: 'PI-1',
            supplier_invoice_no: null,
            branch_id: BRANCH,
            invoice_date: '2026-10-01',
            due_date: '2026-10-08',
            overdue: true,
            total: '11400.00',
            paid: '3000.00',
            returned_credit: '0.00',
            outstanding: '8400.00',
          },
        ],
        total_outstanding: '8400.00',
      }).success,
    ).toBe(true);
    expect(
      PaymentExceedsOutstandingDetail.safeParse({
        purchase_invoice_id: null,
        outstanding: '4100.00',
      }).success,
    ).toBe(true);
    expect(errorCodeHttpStatus.SUPPLIER_PAYMENT_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.PAYMENT_EXCEEDS_OUTSTANDING).toBe(409);
    expect(errorCodeHttpStatus.ALLOCATION_INVALID).toBe(400);
    expect(errorCodeHttpStatus.PAYMENT_ALREADY_REVERSED).toBe(409);
  });
});
