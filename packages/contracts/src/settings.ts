import { z } from 'zod';
import { Uuid, Money, IsoTimestamp } from './common.js';

/**
 * P03 shop settings (D40). Refactored from FinTech-Pro's settings screen: typed fields instead of
 * one `config_data` blob. Column percentages (numeric(5,2)) travel as decimal strings like money;
 * percentages inside JSON settings (discount caps, markup tiers) are plain numbers.
 */

/** Exactly the values of `public.installment_frequency` (daily added in P03). */
export const INSTALLMENT_FREQUENCIES = ['monthly', 'weekly', 'daily'] as const;
export const InstallmentFrequency = z.enum(INSTALLMENT_FREQUENCIES);
export type InstallmentFrequency = z.infer<typeof InstallmentFrequency>;

/** Fields the printed receipt can show or hide. */
export const RECEIPT_FIELDS = [
  'logo',
  'address',
  'phone',
  'tax_registration_no',
  'branch',
  'cashier',
  'customer',
] as const;
export type ReceiptField = (typeof RECEIPT_FIELDS)[number];
export const RECEIPT_WIDTHS_MM = [58, 80] as const;

/** Roles that can have a discount cap. OWNER has no cap. */
export const DISCOUNT_CAP_ROLES = [
  'BRANCH_MANAGER',
  'CASHIER',
  'WAREHOUSE',
  'COLLECTOR',
  'ACCOUNTANT',
  'LAWYER',
] as const;
export const DiscountCapRole = z.enum(DISCOUNT_CAP_ROLES);

export const CREDIT_SCORE_FACTORS = ['guarantors', 'income', 'residence', 'identity'] as const;

export const DOWN_PAYMENT_RULES = [
  'percent',
  'one_installment',
  'installment_per_day_of_month',
] as const;
export const DownPaymentRule = z.enum(DOWN_PAYMENT_RULES);
export type DownPaymentRule = z.infer<typeof DownPaymentRule>;

export const LATE_FEE_TYPES = ['none', 'fixed', 'percent'] as const;
export const EARLY_SETTLEMENT_RULES = [
  'no_discount',
  'waive_future_profit',
  'percent_of_future_profit',
] as const;

const hasTwoDecimalsAtMost = (n: number) => Math.abs(n * 100 - Math.round(n * 100)) < 1e-9;

/** A numeric(5,2) percentage column as a decimal string, 0 to 100. */
export const Percent = z
  .string()
  .regex(/^\d{1,3}(\.\d{1,2})?$/, 'Percent must be a decimal string with at most 2 decimals')
  .refine((v) => Number(v) <= 100, 'Percent must be between 0 and 100');
export type Percent = z.infer<typeof Percent>;

/** A percentage inside a JSON setting, 0 to 100. */
export const PercentValue = z
  .number()
  .min(0)
  .max(100)
  .refine(hasTwoDecimalsAtMost, 'At most 2 decimals');

const PositiveMoney = Money.refine((v) => !v.startsWith('-') && Number(v) > 0, 'Must be above 0');
const NonNegativeMoney = Money.refine((v) => !v.startsWith('-'), 'Must not be negative');
const wholeDays = z.number().int();

export const ReceiptFields = z.object({
  logo: z.boolean(),
  address: z.boolean(),
  phone: z.boolean(),
  tax_registration_no: z.boolean(),
  branch: z.boolean(),
  cashier: z.boolean(),
  customer: z.boolean(),
});
export type ReceiptFields = z.infer<typeof ReceiptFields>;

export const DiscountCaps = z.record(DiscountCapRole, PercentValue);
export type DiscountCaps = z.infer<typeof DiscountCaps>;

export const CreditScoreWeights = z
  .object({
    guarantors: z.number().int().min(0),
    income: z.number().int().min(0),
    residence: z.number().int().min(0),
    identity: z.number().int().min(0),
  })
  .strict()
  .refine((w) => w.guarantors + w.income + w.residence + w.identity === 100, {
    message: 'Weights must add up to 100',
  });
export type CreditScoreWeights = z.infer<typeof CreditScoreWeights>;

export const LegalReferralDays = z.record(InstallmentFrequency, wholeDays.min(1).max(3650));
export type LegalReferralDays = z.infer<typeof LegalReferralDays>;

export const MarkupTier = z
  .object({ up_to_months: z.number().int().min(1).max(120), pct: z.number().min(0).max(500) })
  .strict();
export const AmountTier = z
  .object({ up_to_amount: PositiveMoney, max_months: z.number().int().min(1).max(120) })
  .strict();

const policyFields = {
  min_down_payment_pct: Percent,
  max_down_payment_pct: Percent.nullable(),
  down_payment_rules: z.record(InstallmentFrequency, DownPaymentRule),
  max_months: z.number().int().min(1).max(120),
  amount_tiers: z.array(AmountTier).max(20),
  markup_tiers: z.array(MarkupTier).min(1).max(20),
  allowed_frequencies: z.array(InstallmentFrequency).min(1),
  min_sale_amount: NonNegativeMoney,
  min_installment: NonNegativeMoney,
  min_installment_by_frequency: z.record(InstallmentFrequency, NonNegativeMoney),
  rounding_step: PositiveMoney,
  late_fee_type: z.enum(LATE_FEE_TYPES),
  late_fee_value: NonNegativeMoney,
  late_fee_recurring: z.boolean(),
  late_fee_cap: NonNegativeMoney.nullable(),
  grace_days: wholeDays.min(0).max(365),
  early_settlement_rule: z.enum(EARLY_SETTLEMENT_RULES),
  early_settlement_pct: Percent.nullable(),
  guarantor_required_above: NonNegativeMoney.nullable(),
  /** How many guarantors a contract above `guarantor_required_above` needs (1-3). */
  guarantors_required_count: z.number().int().min(1).max(3),
  survey_required_above: NonNegativeMoney.nullable(),
};

/** One immutable version (a contract keeps the policy id it used). */
export const InstallmentPolicy = z.object({
  id: Uuid,
  version: z.number().int().min(1),
  ...policyFields,
  effective_from: IsoTimestamp,
  created_at: IsoTimestamp,
  created_by: Uuid.nullable(),
});
export type InstallmentPolicy = z.infer<typeof InstallmentPolicy>;
export const InstallmentPolicyList = z.array(InstallmentPolicy);

/**
 * POST /api/settings/installment-policies: the changes for a new version. Keys left out keep the
 * current version's value. Same terms as the current version = no new version.
 */
export const InstallmentPolicyBody = z
  .object(policyFields)
  .partial()
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to change' });
export type InstallmentPolicyBody = z.infer<typeof InstallmentPolicyBody>;

const trimmedOrNull = (max: number) => z.string().trim().max(max).nullable();

const settingsFields = {
  // General
  name: z.string().trim().min(1).max(100),
  address: trimmedOrNull(300),
  phone: trimmedOrNull(30),
  timezone: z.string().min(1).max(64),
  default_language: z.enum(['ar', 'en']),
  logo_file_id: Uuid.nullable(),
  // Receipts
  receipt_header: z.string().max(500).nullable(),
  receipt_footer: z.string().max(500).nullable(),
  receipt_width_mm: z.union([z.literal(58), z.literal(80)]),
  receipt_fields: ReceiptFields,
  // Tax
  prices_include_vat: z.boolean(),
  default_tax_class_id: Uuid.nullable(),
  // Sales and cash
  discount_caps: DiscountCaps,
  return_policy_days: wholeDays.min(0).max(3650),
  purchase_approval_threshold: NonNegativeMoney.nullable(),
  credit_limit_income_multiple: z
    .string()
    .regex(/^\d{1,4}(\.\d{1,2})?$/)
    .nullable(),
  collector_commission_pct: Percent,
  allow_negative_bank: z.boolean(),
  // Appearance
  theme_color: z.string().regex(/^#[0-9A-Fa-f]{6}$/),
  // Credit (R03)
  credit_min_score: wholeDays.min(0).max(100),
  credit_score_weights: CreditScoreWeights,
  // Legal (N04, L01)
  legal_referral_days: LegalReferralDays,
  customer_ban_days: wholeDays.min(0).max(3650),
  overdue_warning_interval_days: wholeDays.min(1).max(365),
  // Inventory (C02)
  global_min_stock: wholeDays.min(0),
  // VAT (T01, D41): to be confirmed with the client's accountant
  installment_markup_vat: z.enum(['not_taxed', 'taxed']),
  delivery_fee_tax_class_id: Uuid.nullable(),
  deposit_vat_timing: z.enum(['on_delivery', 'on_deposit']),
};

export const TaxClassOption = z.object({
  id: Uuid,
  name: z.string(),
  kind: z.enum(['standard', 'zero', 'exempt']),
  rate: Percent,
});

/** GET /api/settings: every employee of the shop may read it. */
export const ShopSettings = z.object({
  ...settingsFields,
  tax_registration_no: trimmedOrNull(50),
  currency: z.literal('EGP'),
  updated_at: IsoTimestamp,
  updated_by: Uuid.nullable(),
  /** The caller's own discount cap (OWNER 100) and whether they may go above it. */
  my_discount: z.object({ cap_pct: z.number().min(0).max(100), above_cap_allowed: z.boolean() }),
  /** The version new installment contracts use; null for a shop that has none yet. */
  installment_policy: InstallmentPolicy.nullable(),
  tax_class_options: z.array(TaxClassOption),
});
export type ShopSettings = z.infer<typeof ShopSettings>;

/**
 * PATCH /api/settings: any subset of the editable fields. receipt_fields and legal_referral_days
 * merge into the stored value; discount_caps replaces it (a role left out has a 0% cap).
 */
export const ShopSettingsUpdateBody = z
  .object({
    ...settingsFields,
    receipt_fields: ReceiptFields.partial(),
  })
  .partial()
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to change' });
export type ShopSettingsUpdateBody = z.infer<typeof ShopSettingsUpdateBody>;
