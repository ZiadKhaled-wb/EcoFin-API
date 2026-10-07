import { describe, it, expect } from 'vitest';
import {
  CreditScoreWeights,
  DiscountCaps,
  InstallmentPolicyBody,
  Percent,
  ShopSettingsUpdateBody,
} from './settings';

describe('P03 settings contracts', () => {
  it('accepts a partial settings update and rejects unknown or empty ones', () => {
    expect(
      ShopSettingsUpdateBody.parse({ name: ' Shop ', receipt_fields: { customer: false } }),
    ).toEqual({ name: 'Shop', receipt_fields: { customer: false } });
    expect(ShopSettingsUpdateBody.safeParse({}).success).toBe(false);
    expect(ShopSettingsUpdateBody.safeParse({ organization_id: 'x' }).success).toBe(false);
    expect(ShopSettingsUpdateBody.safeParse({ currency: 'USD' }).success).toBe(false);
    expect(ShopSettingsUpdateBody.safeParse({ receipt_width_mm: 70 }).success).toBe(false);
    expect(ShopSettingsUpdateBody.safeParse({ theme_color: 'blue' }).success).toBe(false);
  });

  it('caps discounts per non-owner role between 0 and 100', () => {
    expect(DiscountCaps.parse({ CASHIER: 5, BRANCH_MANAGER: 12.5 })).toEqual({
      CASHIER: 5,
      BRANCH_MANAGER: 12.5,
    });
    for (const caps of [{ OWNER: 10 }, { CASHIER: 101 }, { CASHIER: -1 }, { CASHIER: 1.234 }])
      expect(DiscountCaps.safeParse(caps).success).toBe(false);
  });

  it('requires credit score weights that add up to 100', () => {
    expect(
      CreditScoreWeights.safeParse({ guarantors: 40, income: 30, residence: 20, identity: 10 })
        .success,
    ).toBe(true);
    expect(
      CreditScoreWeights.safeParse({ guarantors: 40, income: 30, residence: 20, identity: 5 })
        .success,
    ).toBe(false);
  });

  it('keeps percentages and money as decimal strings', () => {
    expect(Percent.safeParse('12.50').success).toBe(true);
    for (const p of ['100.01', '-1', '1.234', 12]) expect(Percent.safeParse(p).success).toBe(false);
    expect(
      InstallmentPolicyBody.safeParse({ min_installment_by_frequency: { daily: 50 } }).success,
    ).toBe(false);
    expect(
      InstallmentPolicyBody.parse({
        allowed_frequencies: ['monthly', 'daily'],
        down_payment_rules: { daily: 'installment_per_day_of_month' },
        amount_tiers: [{ up_to_amount: '100000.00', max_months: 10 }],
      }).allowed_frequencies,
    ).toEqual(['monthly', 'daily']);
  });

  it('rejects an empty policy body and unknown keys', () => {
    expect(InstallmentPolicyBody.safeParse({}).success).toBe(false);
    expect(InstallmentPolicyBody.safeParse({ version: 2 }).success).toBe(false);
    expect(InstallmentPolicyBody.safeParse({ allowed_frequencies: ['yearly'] }).success).toBe(
      false,
    );
  });
});
