import Big from 'big.js';
import { z } from 'zod';
import { BusinessDate, Money, Uuid } from './common.js';
import { CreditCheck } from './credit.js';
import { GuarantorRequirement, MAX_GUARANTORS_PER_CONTRACT } from './guarantors.js';
import { InstallmentFrequency, type InstallmentPolicy } from './settings.js';
import { SurveyRequirement } from './surveys.js';

/**
 * N01 installment rules engine (D76). An installment sale is a sale at a fixed deferred price
 * (docs/ISLAMIC_FINANCE_RULES.md): from the shop's current policy version and the cashier's inputs
 * the engine gives the financed amount, the profit (markup) for the whole term, the installment
 * price and the schedule lines (principal + profit), all adding up exactly. Nothing here is a rate
 * on time and nothing grows after signing.
 *
 * `app.installment_terms` in the database is the source of truth; `computeInstallmentTerms` below
 * is the same calculation for screens. Both run the golden cases in
 * supabase/tests/fixtures/n01_terms_cases.json.
 */

/** A first due date may be at most this many days after the sale. */
export const FIRST_DUE_MAX_DAYS = 60;
/** The `contracts` CHECK on `installments_count`. */
export const MAX_INSTALLMENTS = 520;

const PositiveMoney = Money.refine((v) => !v.startsWith('-') && !/^0+(\.0+)?$/.test(v), {
  message: 'Must be greater than 0',
});
const NonNegativeMoney = Money.refine((v) => !v.startsWith('-'), { message: 'Not negative' });

const inputFields = {
  cash_price: PositiveMoney,
  down_payment: NonNegativeMoney,
  installments_count: z.number().int().min(1).max(MAX_INSTALLMENTS),
  frequency: InstallmentFrequency,
  /** Defaults to one period after the sale (monthly: same day next month, month end clamped). */
  first_due_date: BusinessDate.optional(),
};

/** What the cashier types: the engine's input. */
export const InstallmentTermsInput = z.object(inputFields).strict();
export type InstallmentTermsInput = z.infer<typeof InstallmentTermsInput>;

export const INSTALLMENT_VIOLATION_RULES = [
  'frequency_not_allowed',
  'sale_below_minimum',
  'down_payment_too_high',
  'down_payment_too_low',
  'too_many_months',
  'installment_below_minimum',
  'rounding',
  'first_due_date_out_of_range',
] as const;
export const InstallmentViolationRule = z.enum(INSTALLMENT_VIOLATION_RULES);
export type InstallmentViolationRule = z.infer<typeof InstallmentViolationRule>;

/** One broken policy rule with the limit it broke. */
export const InstallmentViolation = z.discriminatedUnion('rule', [
  z.object({ rule: z.literal('frequency_not_allowed'), allowed: z.array(InstallmentFrequency) }),
  z.object({ rule: z.literal('sale_below_minimum'), min_sale_amount: Money }),
  z.object({ rule: z.literal('down_payment_too_high'), max_down_payment: Money }),
  z.object({
    rule: z.literal('down_payment_too_low'),
    min_down_payment: Money.nullable(),
    down_payment_rule: z.enum(['percent', 'one_installment', 'installment_per_day_of_month']),
  }),
  z.object({
    rule: z.literal('too_many_months'),
    max_months: z.number().int(),
    duration_months: z.number().int(),
  }),
  z.object({ rule: z.literal('installment_below_minimum'), min_installment: Money }),
  z.object({ rule: z.literal('rounding'), rounding_step: Money }),
  z.object({
    rule: z.literal('first_due_date_out_of_range'),
    earliest: BusinessDate,
    latest: BusinessDate,
  }),
]);
export type InstallmentViolation = z.infer<typeof InstallmentViolation>;

/** One installment: `principal + profit = amount`. */
export const ScheduleLinePreview = z.object({
  seq: z.number().int().min(1),
  due_date: BusinessDate,
  principal: Money,
  profit: Money,
  amount: Money,
});
export type ScheduleLinePreview = z.infer<typeof ScheduleLinePreview>;

/**
 * The engine's answer. `markup_pct` is the profit % for the whole term (never a rate per period),
 * as a decimal string. `lines` is empty when a violation makes a schedule meaningless
 * (`down_payment_too_high`, `rounding`).
 */
export const InstallmentTerms = z.object({
  policy_id: Uuid,
  policy_version: z.number().int().min(1),
  cash_price: Money,
  down_payment: Money,
  financed_amount: Money,
  markup_pct: z.string().regex(/^\d{1,3}(\.\d{1,4})?$/),
  markup_amount: Money,
  total_payable: Money,
  installments_count: z.number().int().min(1).max(MAX_INSTALLMENTS),
  frequency: InstallmentFrequency,
  duration_months: z.number().int().min(1),
  installment_amount: Money.nullable(),
  last_installment_amount: Money.nullable(),
  first_due_date: BusinessDate,
  last_due_date: BusinessDate,
  min_down_payment: Money.nullable(),
  max_down_payment: Money,
  max_months_allowed: z.number().int().min(1),
  lines: z.array(ScheduleLinePreview),
  violations: z.array(InstallmentViolation),
});
export type InstallmentTerms = z.infer<typeof InstallmentTerms>;

/** `POST /api/installments/preview`. The customer and the guarantors are optional. */
export const InstallmentPreviewBody = z
  .object({
    ...inputFields,
    customer_id: Uuid.optional(),
    guarantor_ids: z
      .array(Uuid)
      .max(MAX_GUARANTORS_PER_CONTRACT)
      .refine((ids) => new Set(ids).size === ids.length, { message: 'Duplicate guarantor' })
      .optional(),
  })
  .strict();
export type InstallmentPreviewBody = z.infer<typeof InstallmentPreviewBody>;

/**
 * The R04 requirement plus the guarantors the cashier picked: `selected` counts the picked ones
 * that are linked to the customer and not archived; `selected_met` = the contract would pass R04.
 */
export const InstallmentGuarantorCheck = GuarantorRequirement.extend({
  selected: z.number().int().min(0),
  selected_met: z.boolean(),
});
export type InstallmentGuarantorCheck = z.infer<typeof InstallmentGuarantorCheck>;

export const InstallmentPreview = z.object({
  terms: InstallmentTerms,
  customer: z
    .object({
      credit: CreditCheck,
      guarantors: InstallmentGuarantorCheck,
      survey: SurveyRequirement,
    })
    .nullable(),
  /** No violation, and a customer whose credit, guarantors and survey all pass. */
  can_confirm: z.boolean(),
});
export type InstallmentPreview = z.infer<typeof InstallmentPreview>;

/** Details of `POLICY_CHANGED`: the version the sale must be previewed on again. */
export const PolicyChangedDetail = z.object({ current_version: z.number().int().min(1) });
export type PolicyChangedDetail = z.infer<typeof PolicyChangedDetail>;

/** Details of `INSTALLMENT_TERMS_INVALID`: the broken rules, or the column that doesn't match. */
export const InstallmentTermsInvalidDetail = z.object({
  violations: z.array(InstallmentViolation).optional(),
  mismatch: z.string().optional(),
});
export type InstallmentTermsInvalidDetail = z.infer<typeof InstallmentTermsInvalidDetail>;

// ---------------------------------------------------------------------------------------------
// The engine (same calculation as app.installment_terms). Money is big.js, never a JS number.

const Dec = Big();
Dec.DP = 20;
Dec.RM = Big.roundHalfUp;
Dec.strict = true;
type Dec = Big.Big;

/** The policy fields the engine reads (an `InstallmentPolicy` version). */
export type InstallmentEnginePolicy = Pick<
  InstallmentPolicy,
  | 'id'
  | 'version'
  | 'min_down_payment_pct'
  | 'max_down_payment_pct'
  | 'down_payment_rules'
  | 'max_months'
  | 'amount_tiers'
  | 'markup_tiers'
  | 'allowed_frequencies'
  | 'min_sale_amount'
  | 'min_installment'
  | 'min_installment_by_frequency'
  | 'rounding_step'
>;

const ZERO = Dec('0');
const money = (d: Dec) => {
  const r = d.round(2, Big.roundHalfUp);
  return r.eq(ZERO) ? '0.00' : r.toFixed(2);
};
const num = (v: string | number) => Dec(String(v));

function ymd(date: string): [number, number, number] {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number];
  return [y, m, d];
}
function iso(t: number): string {
  return new Date(t).toISOString().slice(0, 10);
}
function addDays(date: string, days: number): string {
  const [y, m, d] = ymd(date);
  return iso(Date.UTC(y, m - 1, d + days));
}
/** Postgres `date + interval 'n months'`: the same day, clamped to the month's last day. */
function addMonths(date: string, months: number): string {
  const [y, m, d] = ymd(date);
  const first = Date.UTC(y, m - 1 + months, 1);
  const last = new Date(Date.UTC(y, m + months, 0)).getUTCDate();
  const target = new Date(first);
  return iso(Date.UTC(target.getUTCFullYear(), target.getUTCMonth(), Math.min(d, last)));
}

/** Due date of installment `seq` (1-based), always counted from the first due date. */
export function installmentDueDate(first: string, frequency: InstallmentFrequency, seq: number) {
  if (frequency === 'monthly') return addMonths(first, seq - 1);
  return addDays(first, (frequency === 'weekly' ? 7 : 1) * (seq - 1));
}

/** Months the plan lasts, for the markup tier and the month limits. */
export function installmentDurationMonths(frequency: InstallmentFrequency, count: number): number {
  if (frequency === 'monthly') return count;
  return Math.ceil((frequency === 'weekly' ? count * 7 : count) / 30);
}

/** The regular installment: total / n rounded up to a multiple of the step (n = 1: the total). */
function regularInstallment(total: Dec, count: number, step: Dec): Dec {
  if (count === 1) return total;
  return total
    .div(step.times(String(count)))
    .round(0, Big.roundUp)
    .times(step);
}

/** Markup and total for a financed amount at a whole-term %. */
function priced(financed: Dec, pct: Dec) {
  const markup = financed.gt(ZERO)
    ? financed.times(pct).div('100').round(2, Big.roundHalfUp)
    : ZERO;
  return { markup, total: financed.plus(markup) };
}

/** Largest remainder in piasters: `amount` split by `weights`, ties to the earlier part. */
function allocate(amount: Dec, weights: Dec[]): Dec[] {
  const p = amount.times('100');
  const total = weights.reduce((a, w) => a.plus(w), ZERO);
  const shares = weights.map((w, index) => {
    const n = p.times(w);
    const floor = n.div(total).round(0, Big.roundDown);
    return { index, floor, rest: n.minus(floor.times(total)) };
  });
  const left = Number(p.minus(shares.reduce((a, s) => a.plus(s.floor), ZERO)).toFixed(0));
  [...shares]
    .sort((a, b) => b.rest.cmp(a.rest) || a.index - b.index)
    .slice(0, left)
    .forEach((s) => (s.floor = s.floor.plus('1')));
  return shares.map((s) => s.floor.div('100'));
}

/**
 * The terms of an installment sale under one policy version. `today` is the sale date in the
 * shop's timezone (YYYY-MM-DD). Pure: the same inputs always give the same answer.
 */
export function computeInstallmentTerms(
  policy: InstallmentEnginePolicy,
  input: InstallmentTermsInput,
  today: string,
): InstallmentTerms {
  const freq = input.frequency;
  const n = input.installments_count;
  const cash = num(input.cash_price);
  const down = num(input.down_payment);
  const step = num(policy.rounding_step);
  const violations: InstallmentViolation[] = [];

  const duration = installmentDurationMonths(freq, n);
  const tiers = policy.markup_tiers;
  const tier = tiers.find((t) => t.up_to_months >= duration) ?? tiers[tiers.length - 1]!;
  const pct = num(tier.pct).round(4, Big.roundHalfUp);

  const financed = cash.minus(down);
  const { markup, total } = priced(financed.gt(ZERO) ? financed : ZERO, pct);
  const installment = financed.gt(ZERO) ? regularInstallment(total, n, step) : null;
  const last = installment ? total.minus(installment.times(String(n - 1))) : null;
  const linesOk = installment !== null && last !== null && last.gt(ZERO);

  // Down payment limits.
  const capPct = policy.max_down_payment_pct;
  const below = cash.minus('0.01');
  const cap =
    capPct === null ? below : num(capPct).times(cash).div('100').round(2, Big.roundHalfUp);
  const maxDown = cap.lt(below) ? cap : below;
  const rule = policy.down_payment_rules[freq] ?? 'percent';
  const dayFactor = rule === 'installment_per_day_of_month' ? ymd(today)[2] : 1;
  const passes = (d: Dec) => {
    const { total: t } = priced(cash.minus(d), pct);
    return d.gte(regularInstallment(t, n, step).times(String(dayFactor)));
  };
  let minDown: Dec | null;
  if (rule === 'percent') {
    minDown = num(policy.min_down_payment_pct).times(cash).div('100').round(2, Big.roundHalfUp);
  } else {
    // The smallest down payment (in piasters, below the cash price) with down >= its installment(s).
    let lo = 0;
    let hi = Number(below.times('100').toFixed(0));
    const at = (p: number) => Dec(String(p)).div('100');
    if (hi < 0 || !passes(at(hi))) minDown = null;
    else {
      while (lo < hi) {
        const mid = Math.floor((lo + hi) / 2);
        if (passes(at(mid))) hi = mid;
        else lo = mid + 1;
      }
      minDown = at(lo);
    }
  }

  // Month limits.
  const amountTier = policy.amount_tiers.find((t) => num(t.up_to_amount).gte(cash));
  const maxMonths = Math.min(policy.max_months, amountTier?.max_months ?? policy.max_months);

  // Dates.
  const period = (d: string) =>
    freq === 'monthly' ? addMonths(d, 1) : addDays(d, freq === 'weekly' ? 7 : 1);
  const first = input.first_due_date ?? period(today);
  const earliest = addDays(today, 1);
  const latest = addDays(today, FIRST_DUE_MAX_DAYS);

  if (!policy.allowed_frequencies.includes(freq)) {
    violations.push({ rule: 'frequency_not_allowed', allowed: [...policy.allowed_frequencies] });
  }
  if (cash.lt(num(policy.min_sale_amount))) {
    violations.push({
      rule: 'sale_below_minimum',
      min_sale_amount: money(num(policy.min_sale_amount)),
    });
  }
  if (down.gt(maxDown)) {
    violations.push({ rule: 'down_payment_too_high', max_down_payment: money(maxDown) });
  } else if (minDown === null || down.lt(minDown)) {
    violations.push({
      rule: 'down_payment_too_low',
      min_down_payment: minDown === null ? null : money(minDown),
      down_payment_rule: rule,
    });
  }
  if (duration > maxMonths) {
    violations.push({ rule: 'too_many_months', max_months: maxMonths, duration_months: duration });
  }
  const general = num(policy.min_installment);
  const byFreq = num(policy.min_installment_by_frequency[freq] ?? '0');
  const minInstallment = general.gte(byFreq) ? general : byFreq;
  if (installment && installment.lt(minInstallment)) {
    violations.push({ rule: 'installment_below_minimum', min_installment: money(minInstallment) });
  }
  if (installment && !linesOk) {
    violations.push({ rule: 'rounding', rounding_step: money(step) });
  }
  if (first < earliest || first > latest) {
    violations.push({ rule: 'first_due_date_out_of_range', earliest, latest });
  }

  const lines: ScheduleLinePreview[] = [];
  if (linesOk && installment && last) {
    const amounts = Array.from({ length: n }, (_, i) => (i === n - 1 ? last : installment));
    const profits = markup.gt(ZERO) ? allocate(markup, amounts) : amounts.map(() => ZERO);
    amounts.forEach((amount, i) =>
      lines.push({
        seq: i + 1,
        due_date: installmentDueDate(first, freq, i + 1),
        principal: money(amount.minus(profits[i]!)),
        profit: money(profits[i]!),
        amount: money(amount),
      }),
    );
  }

  return {
    policy_id: policy.id,
    policy_version: policy.version,
    cash_price: money(cash),
    down_payment: money(down),
    financed_amount: money(financed.gt(ZERO) ? financed : ZERO),
    markup_pct: pct.toString(),
    markup_amount: money(markup),
    total_payable: money(total),
    installments_count: n,
    frequency: freq,
    duration_months: duration,
    installment_amount: installment ? money(installment) : null,
    last_installment_amount: linesOk && last ? money(last) : null,
    first_due_date: first,
    last_due_date: installmentDueDate(first, freq, n),
    min_down_payment: minDown === null ? null : money(minDown),
    max_down_payment: money(maxDown),
    max_months_allowed: maxMonths,
    lines,
    violations,
  };
}
