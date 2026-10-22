import { describe, expect, it } from 'vitest';
import {
  RefundLines,
  SalesReturnCreateBody,
  SalesReturnQuoteBody,
  errorCodeHttpStatus,
} from './index.js';

const SALE = 'a0500000-0000-4000-8000-000000000001';
const LINE = 'a0500000-0000-4000-8000-000000000002';
const UNIT = 'a0500000-0000-4000-8000-000000000003';
const base = {
  sale_id: SALE,
  lines: [{ sale_line_id: LINE, quantity: 1 }],
  reason: 'Customer changed his mind',
  expected_total: '250.00',
};

describe('S05 returns contract', () => {
  it('a return: condition defaults to resellable, no refund lines means an empty list', () => {
    const parsed = SalesReturnCreateBody.parse(base);
    expect(parsed.kind).toBe('return');
    expect(parsed.lines[0]!.condition).toBe('resellable');
    expect(parsed.refunds).toEqual([]);
  });

  it('refuses an organization id, a line twice, a serial with quantity 2 and a short reason', () => {
    expect(SalesReturnCreateBody.safeParse({ ...base, organization_id: SALE }).success).toBe(false);
    expect(
      SalesReturnCreateBody.safeParse({ ...base, lines: [base.lines[0], base.lines[0]] }).success,
    ).toBe(false);
    expect(
      SalesReturnCreateBody.safeParse({
        ...base,
        lines: [{ sale_line_id: LINE, unit_id: UNIT, quantity: 2 }],
      }).success,
    ).toBe(false);
    expect(SalesReturnCreateBody.safeParse({ ...base, reason: 'no' }).success).toBe(false);
  });

  it('money stays a string; negative or float amounts are refused', () => {
    expect(SalesReturnCreateBody.safeParse({ ...base, expected_total: 250 }).success).toBe(false);
    expect(SalesReturnCreateBody.safeParse({ ...base, expected_total: '-1.00' }).success).toBe(
      false,
    );
    expect(RefundLines.safeParse([{ method: 'cash', amount: '0' }]).success).toBe(false);
  });

  it('refund lines: one cash, one store credit, a bank transfer needs its bank and reference', () => {
    expect(
      RefundLines.safeParse([
        { method: 'cash', amount: '1.00' },
        { method: 'cash', amount: '2.00' },
      ]).success,
    ).toBe(false);
    expect(RefundLines.safeParse([{ method: 'bank_transfer', amount: '1.00' }]).success).toBe(
      false,
    );
    expect(
      RefundLines.safeParse([
        { method: 'bank_transfer', amount: '1.00', cash_account_id: SALE, reference: 'T1' },
        { method: 'bank_transfer', amount: '1.00', cash_account_id: UNIT, reference: 'T2' },
        { method: 'store_credit', amount: '1.00' },
      ]).success,
    ).toBe(true);
  });

  it('an exchange needs a new sale with its total; a return can not carry one', () => {
    const newSale = {
      lines: [{ product_id: UNIT, quantity: 1 }],
      expected_total: '4000.00',
    };
    expect(
      SalesReturnCreateBody.safeParse({ ...base, kind: 'exchange', new_sale: newSale }).success,
    ).toBe(true);
    expect(SalesReturnCreateBody.safeParse({ ...base, kind: 'exchange' }).success).toBe(false);
    expect(SalesReturnCreateBody.safeParse({ ...base, new_sale: newSale }).success).toBe(false);
    expect(
      SalesReturnCreateBody.safeParse({
        ...base,
        kind: 'exchange',
        new_sale: { lines: newSale.lines },
      }).success,
    ).toBe(false);
    // The quote works out the new sale's total itself.
    expect(
      SalesReturnQuoteBody.safeParse({
        sale_id: SALE,
        lines: base.lines,
        kind: 'exchange',
        new_sale: { lines: newSale.lines },
      }).success,
    ).toBe(true);
  });

  it('the new error codes and their statuses', () => {
    expect(errorCodeHttpStatus.RETURN_NOT_FOUND).toBe(404);
    for (const code of [
      'RETURN_UNIT_MISMATCH',
      'RETURN_PERIOD_EXPIRED',
      'RETURN_OTHER_BRANCH',
      'REFUND_EXCEEDS_PAID',
      'RETURN_ETA_WINDOW_PASSED',
      'EXCHANGE_NOT_FOR_CONTRACT',
    ] as const) {
      expect(errorCodeHttpStatus[code]).toBe(409);
    }
  });
});
