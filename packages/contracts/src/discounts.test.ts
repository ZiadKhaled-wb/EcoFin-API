import { describe, it, expect } from 'vitest';
import {
  Discount,
  DiscountAboveCapDetail,
  DiscountApprovalDecideBody,
  DiscountApprovalListQuery,
  DiscountApprovalRequestBody,
  SaleCreateBody,
  SaleLineInput,
  SaleQuoteBody,
} from './sales.js';
import { errorCodeHttpStatus } from './errors.js';

const CHAIR = 'a0620000-0000-4000-8000-000000000001';
const BRANCH = 'a0620000-0000-4000-8000-000000000002';

describe('S03 discount contracts', () => {
  it('a discount is an amount or a percent: decimal strings, percent 0-100, at most 2 decimals', () => {
    expect(Discount.safeParse({ type: 'amount', value: '10.50' }).success).toBe(true);
    expect(Discount.safeParse({ type: 'amount', value: '1500' }).success).toBe(true);
    expect(Discount.safeParse({ type: 'percent', value: '5' }).success).toBe(true);
    expect(Discount.safeParse({ type: 'percent', value: '100' }).success).toBe(true);
    expect(Discount.safeParse({ type: 'percent', value: '100.00' }).success).toBe(true);
    expect(Discount.safeParse({ type: 'percent', value: '0' }).success).toBe(true);
    expect(Discount.safeParse({ type: 'percent', value: '100.01' }).success).toBe(false);
    expect(Discount.safeParse({ type: 'percent', value: '5.001' }).success).toBe(false);
    expect(Discount.safeParse({ type: 'percent', value: '-1' }).success).toBe(false);
    expect(Discount.safeParse({ type: 'amount', value: '-1.00' }).success).toBe(false);
    expect(Discount.safeParse({ type: 'amount', value: '1.005' }).success).toBe(false);
    // Money is never a JS number.
    expect(Discount.safeParse({ type: 'amount', value: 10 }).success).toBe(false);
    expect(Discount.safeParse({ type: 'percent', value: 5 }).success).toBe(false);
    expect(Discount.safeParse({ type: 'fixed', value: '5' }).success).toBe(false);
    expect(Discount.safeParse({ type: 'amount', value: '5', extra: 1 }).success).toBe(false);
  });

  it('a sale line, the quote and the sale take the discounts; the reason is 3-200 characters', () => {
    const discount = { type: 'percent', value: '5' };
    expect(SaleLineInput.safeParse({ product_id: CHAIR, quantity: 1, discount }).success).toBe(
      true,
    );
    const lines = [{ product_id: CHAIR, quantity: 2, discount }];
    expect(SaleQuoteBody.safeParse({ lines, sale_discount: discount }).success).toBe(true);
    const body = { lines, expected_total: '10.00', sale_discount: discount };
    expect(SaleCreateBody.safeParse({ ...body, discount_reason: 'Regular customer' }).success).toBe(
      true,
    );
    expect(SaleCreateBody.safeParse({ ...body, discount_reason: 'ab' }).success).toBe(false);
    expect(SaleCreateBody.safeParse({ ...body, discount_reason: 'x'.repeat(201) }).success).toBe(
      false,
    );
    expect(SaleCreateBody.safeParse({ ...body, discount_reason: 'x'.repeat(200) }).success).toBe(
      true,
    );
    expect(SaleCreateBody.safeParse({ ...body, discount_approval_id: 'not-a-uuid' }).success).toBe(
      false,
    );
    expect(SaleCreateBody.safeParse({ ...body, discount_approval_id: BRANCH }).success).toBe(true);
  });

  it('a fingerprint sent by the client is refused (strict): the server computes it', () => {
    const lines = [{ product_id: CHAIR, quantity: 1 }];
    expect(
      SaleCreateBody.safeParse({ lines, expected_total: '1.00', fingerprint: 'abc' }).success,
    ).toBe(false);
    expect(
      DiscountApprovalRequestBody.safeParse({
        branch_id: BRANCH,
        lines,
        reason: 'Regular customer',
        fingerprint: 'abc',
      }).success,
    ).toBe(false);
    expect(
      SaleLineInput.safeParse({ product_id: CHAIR, quantity: 1, fingerprint: 'abc' }).success,
    ).toBe(false);
  });

  it('the request body, the decision and the list query', () => {
    const lines = [{ product_id: CHAIR, quantity: 1, discount: { type: 'percent', value: '8' } }];
    expect(
      DiscountApprovalRequestBody.safeParse({
        branch_id: BRANCH,
        lines,
        reason: 'Regular customer',
      }).success,
    ).toBe(true);
    expect(DiscountApprovalRequestBody.safeParse({ branch_id: BRANCH, lines }).success).toBe(false);
    expect(
      DiscountApprovalRequestBody.safeParse({ branch_id: BRANCH, lines, reason: 'no' }).success,
    ).toBe(false);
    expect(DiscountApprovalDecideBody.safeParse({ approve: true }).success).toBe(true);
    expect(DiscountApprovalDecideBody.safeParse({ approve: false, note: 'Too much' }).success).toBe(
      true,
    );
    expect(DiscountApprovalDecideBody.safeParse({ note: 'x' }).success).toBe(false);
    expect(DiscountApprovalDecideBody.safeParse({ approve: 'yes' }).success).toBe(false);
    expect(DiscountApprovalListQuery.parse({})).toEqual({
      kind: 'discount_above_cap',
      status: 'pending',
    });
    expect(DiscountApprovalListQuery.safeParse({ kind: 'purchase_invoice' }).success).toBe(false);
    expect(DiscountApprovalListQuery.safeParse({ status: 'open' }).success).toBe(false);
  });

  it('the cap detail and the error codes with their HTTP statuses', () => {
    expect(
      DiscountAboveCapDetail.safeParse({ line_no: 1, cap_pct: '5.00', effective_pct: '6.00' })
        .success,
    ).toBe(true);
    expect(errorCodeHttpStatus.DISCOUNT_ABOVE_CAP).toBe(403);
    expect(errorCodeHttpStatus.DISCOUNT_INVALID).toBe(400);
    expect(errorCodeHttpStatus.DISCOUNT_REASON_REQUIRED).toBe(400);
    expect(errorCodeHttpStatus.APPROVAL_INVALID).toBe(409);
    expect(errorCodeHttpStatus.APPROVAL_NOT_NEEDED).toBe(400);
    expect(errorCodeHttpStatus.APPROVAL_NOT_PENDING).toBe(409);
    expect(errorCodeHttpStatus.APPROVAL_SELF).toBe(403);
    expect(errorCodeHttpStatus.APPROVAL_NOT_FOUND).toBe(404);
  });
});
