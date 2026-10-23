import { describe, expect, it } from 'vitest';
import { CreateQuotationBody, QuotationReasonBody } from './quotations.js';
describe('S09 contracts', () => {
  it('A4 ignores client tax and totals, keeping decimal input', () => {
    const body = CreateQuotationBody.parse({
      branch_id: 'd2000000-0000-4000-8000-000000000011',
      lines: [
        {
          product_id: null,
          description: 'Custom',
          quantity: 1,
          unit_price: '120.00',
          discount_amount: '0',
          tax_amount: '999',
          line_total: '999',
        },
      ],
      total: '999',
    });
    expect(body).not.toHaveProperty('total');
    expect(body.lines[0]).not.toHaveProperty('tax_amount');
    expect(body.lines[0]?.unit_price).toBe('120.00');
  });
  it('Q6 rejects empty/oversized line lists and numeric money', () => {
    const base = { branch_id: 'd2000000-0000-4000-8000-000000000011' };
    expect(CreateQuotationBody.safeParse({ ...base, lines: [] }).success).toBe(false);
    expect(
      CreateQuotationBody.safeParse({
        ...base,
        lines: Array(201).fill({ quantity: 1, unit_price: '1' }),
      }).success,
    ).toBe(false);
    expect(
      CreateQuotationBody.safeParse({ ...base, lines: [{ quantity: 1, unit_price: 1 }] }).success,
    ).toBe(false);
  });
  it('Q10 requires a meaningful bounded reason', () => {
    for (const reason of ['', '  ', 'ab', 'x'.repeat(501)])
      expect(QuotationReasonBody.safeParse({ reason }).success).toBe(false);
    expect(QuotationReasonBody.parse({ reason: ' declined ' }).reason).toBe('declined');
  });
});
