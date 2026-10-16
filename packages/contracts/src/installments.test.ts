import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  computeInstallmentTerms,
  Contract,
  InstallmentSaleBody,
  InstallmentPreview,
  InstallmentPreviewBody,
  InstallmentTerms,
  InstallmentTermsInput,
  installmentDueDate,
  installmentDurationMonths,
  type InstallmentEnginePolicy,
} from './installments';
import { addMoney, sumMoney } from './money';

interface GoldenCase {
  id: string;
  title: string;
  today: string;
  policy: InstallmentEnginePolicy;
  input: InstallmentTermsInput;
  expected: unknown;
}
const golden = JSON.parse(
  readFileSync(
    new URL('../../../supabase/tests/fixtures/n01_terms_cases.json', import.meta.url),
    'utf8',
  ),
) as { cases: GoldenCase[] };

const policy = (over: Partial<InstallmentEnginePolicy> = {}): InstallmentEnginePolicy => ({
  id: '00000000-0000-4000-8000-0000000000b1',
  version: 3,
  min_down_payment_pct: '10',
  max_down_payment_pct: null,
  down_payment_rules: {},
  max_months: 24,
  amount_tiers: [],
  markup_tiers: [
    { up_to_months: 6, pct: 10 },
    { up_to_months: 24, pct: 20 },
  ],
  allowed_frequencies: ['monthly', 'weekly', 'daily'],
  min_sale_amount: '0.00',
  min_installment: '0.00',
  min_installment_by_frequency: {},
  rounding_step: '1.00',
  ...over,
});
const TODAY = '2026-10-15';
const input = (over: Partial<InstallmentTermsInput> = {}): InstallmentTermsInput => ({
  cash_price: '14000.00',
  down_payment: '2000.00',
  installments_count: 12,
  frequency: 'monthly',
  ...over,
});
const rules = (t: InstallmentTerms) => t.violations.map((v) => v.rule);

describe('N01 golden cases', () => {
  it('has at least 30 cases', () => {
    expect(golden.cases.length).toBeGreaterThanOrEqual(30);
  });
  for (const c of golden.cases) {
    it(`${c.id}: ${c.title}`, () => {
      const terms = computeInstallmentTerms(c.policy, c.input, c.today);
      expect(InstallmentTerms.parse(terms)).toEqual(terms);
      expect(terms).toEqual(c.expected);
    });
  }
});

describe('computeInstallmentTerms', () => {
  it('prices a 12-month sale at the 20 % tier: profit for the whole term, 12 equal installments', () => {
    const t = computeInstallmentTerms(policy(), input(), TODAY);
    expect(t).toMatchObject({
      policy_id: '00000000-0000-4000-8000-0000000000b1',
      policy_version: 3,
      financed_amount: '12000.00',
      markup_pct: '20',
      markup_amount: '2400.00',
      total_payable: '14400.00',
      installment_amount: '1200.00',
      last_installment_amount: '1200.00',
      first_due_date: '2026-11-15',
      last_due_date: '2027-10-15',
      violations: [],
    });
    expect(t.lines).toHaveLength(12);
    expect(t.lines[0]).toEqual({
      seq: 1,
      due_date: '2026-11-15',
      principal: '1000.00',
      profit: '200.00',
      amount: '1200.00',
    });
  });

  it('always adds up: amounts to the total, principal to the financed amount, profit to the markup', () => {
    for (const step of ['0.01', '1.00', '5.00']) {
      for (const n of [1, 2, 3, 7, 11, 13, 24]) {
        for (const cash of ['999.99', '1234.56', '25000.00']) {
          const t = computeInstallmentTerms(
            policy({ rounding_step: step, min_down_payment_pct: '0' }),
            input({ cash_price: cash, down_payment: '0.00', installments_count: n }),
            TODAY,
          );
          if (t.lines.length === 0) continue;
          expect(sumMoney(t.lines.map((l) => l.amount))).toBe(t.total_payable);
          expect(sumMoney(t.lines.map((l) => l.principal))).toBe(t.financed_amount);
          expect(sumMoney(t.lines.map((l) => l.profit))).toBe(t.markup_amount);
          for (const l of t.lines) expect(addMoney(l.principal, l.profit)).toBe(l.amount);
          expect(t.lines.map((l) => l.seq)).toEqual(Array.from({ length: n }, (_, i) => i + 1));
        }
      }
    }
  });

  it('rounds the installment up to the step and leaves the rest to the last line', () => {
    const t = computeInstallmentTerms(
      policy({ markup_tiers: [{ up_to_months: 24, pct: 0 }], min_down_payment_pct: '0' }),
      input({ cash_price: '1000.00', down_payment: '0.00', installments_count: 3 }),
      TODAY,
    );
    expect(t.lines.map((l) => l.amount)).toEqual(['334.00', '334.00', '332.00']);
  });

  it('reports a rounding step too big for the number of installments', () => {
    const t = computeInstallmentTerms(
      policy({ rounding_step: '50.00', min_down_payment_pct: '0' }),
      input({
        cash_price: '100.00',
        down_payment: '0.00',
        installments_count: 10,
        frequency: 'weekly',
      }),
      TODAY,
    );
    expect(rules(t)).toEqual(['rounding']);
    expect(t.lines).toEqual([]);
    expect(t.last_installment_amount).toBeNull();
  });

  it('refuses a down payment at or above the cash price and gives no schedule', () => {
    const t = computeInstallmentTerms(policy(), input({ down_payment: '14000.00' }), TODAY);
    expect(t.violations).toEqual([{ rule: 'down_payment_too_high', max_down_payment: '13999.99' }]);
    expect(t.financed_amount).toBe('0.00');
    expect(t.installment_amount).toBeNull();
    expect(t.lines).toEqual([]);
  });

  it('applies the percent minimum half-up, one piaster below fails', () => {
    const low = computeInstallmentTerms(policy(), input({ down_payment: '1399.99' }), TODAY);
    expect(low.violations).toEqual([
      { rule: 'down_payment_too_low', min_down_payment: '1400.00', down_payment_rule: 'percent' },
    ]);
    expect(
      computeInstallmentTerms(policy(), input({ down_payment: '1400.00' }), TODAY).violations,
    ).toEqual([]);
  });

  it('finds the smallest down payment that covers one installment', () => {
    const p = policy({ down_payment_rules: { monthly: 'one_installment' } });
    const t = computeInstallmentTerms(p, input({ down_payment: '0.00' }), TODAY);
    const min = t.min_down_payment!;
    expect(computeInstallmentTerms(p, input({ down_payment: min }), TODAY).violations).toEqual([]);
    const below = computeInstallmentTerms(
      p,
      input({ down_payment: addMoney(min, '-0.01') }),
      TODAY,
    );
    expect(rules(below)).toEqual(['down_payment_too_low']);
  });

  it('counts one installment per day of the month so far for daily plans', () => {
    const p = policy({
      down_payment_rules: { daily: 'installment_per_day_of_month' },
      markup_tiers: [{ up_to_months: 24, pct: 0 }],
    });
    const t = computeInstallmentTerms(
      p,
      input({
        cash_price: '3000.00',
        down_payment: '600.00',
        installments_count: 60,
        frequency: 'daily',
      }),
      '2026-10-10',
    );
    expect(t.installment_amount).toBe('40.00');
    expect(t.min_down_payment).toBe('430.00');
    expect(t.violations).toEqual([]);
  });

  it('limits months by max_months and by the amount tier', () => {
    expect(
      computeInstallmentTerms(policy(), input({ installments_count: 25 }), TODAY).violations,
    ).toContainEqual({ rule: 'too_many_months', max_months: 24, duration_months: 25 });
    const tiered = policy({ amount_tiers: [{ up_to_amount: '20000.00', max_months: 6 }] });
    const t = computeInstallmentTerms(tiered, input({ installments_count: 7 }), TODAY);
    expect(t.max_months_allowed).toBe(6);
    expect(rules(t)).toEqual(['too_many_months']);
  });

  it('checks the minimum installment (the per-frequency one when higher) but not the last line', () => {
    const p = policy({
      min_installment: '100.00',
      min_installment_by_frequency: { monthly: '1500.00' },
    });
    expect(computeInstallmentTerms(p, input(), TODAY).violations).toEqual([
      { rule: 'installment_below_minimum', min_installment: '1500.00' },
    ]);
  });

  it('keeps the first due date between tomorrow and 60 days out', () => {
    const at = (d: string) =>
      computeInstallmentTerms(policy(), input({ first_due_date: d }), TODAY).violations;
    expect(at('2026-10-15')).toEqual([
      { rule: 'first_due_date_out_of_range', earliest: '2026-10-16', latest: '2026-12-14' },
    ]);
    expect(at('2026-10-16')).toEqual([]);
    expect(at('2026-12-14')).toEqual([]);
    expect(
      rules(computeInstallmentTerms(policy(), input({ first_due_date: '2026-12-15' }), TODAY)),
    ).toEqual(['first_due_date_out_of_range']);
  });

  it('refuses a frequency the policy does not allow', () => {
    const t = computeInstallmentTerms(
      policy({ allowed_frequencies: ['monthly'] }),
      input({ frequency: 'weekly', installments_count: 8 }),
      TODAY,
    );
    expect(t.violations[0]).toEqual({ rule: 'frequency_not_allowed', allowed: ['monthly'] });
  });
});

describe('dates and durations', () => {
  it('counts months from the first due date and clamps month ends', () => {
    expect([1, 2, 3, 4].map((s) => installmentDueDate('2027-01-31', 'monthly', s))).toEqual([
      '2027-01-31',
      '2027-02-28',
      '2027-03-31',
      '2027-04-30',
    ]);
    expect(installmentDueDate('2028-01-31', 'monthly', 2)).toBe('2028-02-29');
    expect(installmentDueDate('2026-12-29', 'weekly', 2)).toBe('2027-01-05');
    expect(installmentDueDate('2026-12-31', 'daily', 2)).toBe('2027-01-01');
  });
  it('turns weeks and days into months, rounding up', () => {
    expect(installmentDurationMonths('weekly', 10)).toBe(3);
    expect(installmentDurationMonths('daily', 45)).toBe(2);
    expect(installmentDurationMonths('daily', 30)).toBe(1);
    expect(installmentDurationMonths('monthly', 7)).toBe(7);
  });
});

describe('schemas', () => {
  it('accepts a preview body with a customer and up to three different guarantors', () => {
    const ok = InstallmentPreviewBody.safeParse({
      ...input(),
      customer_id: '00000000-0000-4000-8000-0000000000c1',
      guarantor_ids: ['00000000-0000-4000-8000-0000000000d1'],
    });
    expect(ok.success).toBe(true);
  });
  it('refuses an injected organization id, a repeated guarantor and 521 installments', () => {
    expect(InstallmentPreviewBody.safeParse({ ...input(), organization_id: 'x' }).success).toBe(
      false,
    );
    const g = '00000000-0000-4000-8000-0000000000d1';
    expect(InstallmentPreviewBody.safeParse({ ...input(), guarantor_ids: [g, g] }).success).toBe(
      false,
    );
    expect(InstallmentTermsInput.safeParse(input({ installments_count: 521 })).success).toBe(false);
    expect(InstallmentTermsInput.safeParse(input({ cash_price: '0.00' })).success).toBe(false);
    expect(InstallmentTermsInput.safeParse(input({ down_payment: '-1.00' })).success).toBe(false);
  });
  it('parses a preview without a customer', () => {
    const terms = computeInstallmentTerms(policy(), input(), TODAY);
    expect(InstallmentPreview.parse({ terms, customer: null, can_confirm: false }).terms).toEqual(
      terms,
    );
  });
});

describe('N02 installment sale schemas', () => {
  const id = '00000000-0000-4000-8000-000000000001';
  const body = {
    lines: [{ product_id: id, quantity: 1 }],
    expected_total: '12000.00',
    customer_id: id,
    terms: {
      down_payment: '2000.00',
      installments_count: 12,
      frequency: 'monthly',
      policy_version: 3,
    },
  };

  it('accepts a sale and defaults guarantor_ids to []', () => {
    const r = InstallmentSaleBody.parse(body);
    expect(r.guarantor_ids).toEqual([]);
  });

  it('needs a customer and the policy version', () => {
    expect(InstallmentSaleBody.safeParse({ ...body, customer_id: undefined }).success).toBe(false);
    const { policy_version: _pv, ...terms } = body.terms;
    expect(InstallmentSaleBody.safeParse({ ...body, terms }).success).toBe(false);
  });

  it('refuses unknown keys, a zero cash price, duplicate or too many guarantors', () => {
    expect(InstallmentSaleBody.safeParse({ ...body, organization_id: id }).success).toBe(false);
    expect(InstallmentSaleBody.safeParse({ ...body, expected_total: '0.00' }).success).toBe(false);
    expect(InstallmentSaleBody.safeParse({ ...body, guarantor_ids: [id, id] }).success).toBe(false);
    const ids = ['1', '2', '3', '4'].map((n) => `00000000-0000-4000-8000-00000000000${n}`);
    expect(InstallmentSaleBody.safeParse({ ...body, guarantor_ids: ids }).success).toBe(false);
    expect(
      InstallmentSaleBody.safeParse({ ...body, terms: { ...body.terms, cash_price: '1.00' } })
        .success,
    ).toBe(false);
  });

  it('takes the down payment lines', () => {
    const r = InstallmentSaleBody.safeParse({
      ...body,
      payments: [{ method: 'cash', amount: '2000.00' }],
    });
    expect(r.success).toBe(true);
  });

  it('parses a contract answer', () => {
    const contract = {
      id,
      number: 'MAIN-CT-26-000001',
      status: 'active',
      branch_id: id,
      sale_id: id,
      sale_number: 'MAIN-SL-26-000001',
      customer: { id, name: 'Good Customer', phone: '01000000001' },
      guarantors: [{ id, name: 'First Guarantor', relation: 'brother' }],
      policy_version: 1,
      creditor: 'in_house',
      cash_price: '12000.00',
      down_payment: '2000.00',
      financed_amount: '10000.00',
      markup_pct: '20',
      markup_amount: '2000.00',
      total_payable: '12000.00',
      installments_count: 1,
      frequency: 'monthly',
      first_due_date: '2026-11-16',
      last_due_date: '2026-11-16',
      current_version: 1,
      credit_approval_id: null,
      created_at: '2026-10-16T06:12:02.830466+00:00',
      created_by_name: 'N02 Cashier',
      lines: [
        {
          seq: 1,
          due_date: '2026-11-16',
          principal: '10000.00',
          profit: '2000.00',
          amount: '12000.00',
          paid: '0.00',
          remaining: '12000.00',
          status: 'upcoming',
        },
      ],
      balance: { paid: '0.00', remaining: '12000.00', overdue: '0.00' },
    };
    expect(Contract.safeParse(contract).success).toBe(true);
    expect(Contract.safeParse({ ...contract, markup_pct: '12.34567' }).success).toBe(false);
  });
});
