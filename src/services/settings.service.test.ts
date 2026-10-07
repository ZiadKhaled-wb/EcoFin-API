import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import { getSettings, updateSettings, publishPolicy } from './settings.service';

const ID = 'a0300000-0000-4000-8000-000000000001';
const policy = {
  id: ID,
  version: 2,
  min_down_payment_pct: '10.00',
  max_down_payment_pct: '50.00',
  down_payment_rules: { daily: 'installment_per_day_of_month' },
  max_months: 15,
  amount_tiers: [{ up_to_amount: '100000.00', max_months: 10 }],
  markup_tiers: [{ up_to_months: 15, pct: 25 }],
  allowed_frequencies: ['monthly', 'daily'],
  min_sale_amount: '2500.00',
  min_installment: '0.00',
  min_installment_by_frequency: { daily: '50.00' },
  rounding_step: '1.00',
  late_fee_type: 'none',
  late_fee_value: '0.00',
  late_fee_recurring: false,
  late_fee_cap: null,
  grace_days: 3,
  early_settlement_rule: 'no_discount',
  early_settlement_pct: null,
  guarantor_required_above: null,
  survey_required_above: null,
  effective_from: '2026-10-07T09:00:00.123456+00:00',
  created_at: '2026-10-07T09:00:00.123456+00:00',
  created_by: ID,
};
const settings = {
  name: 'Shop',
  address: null,
  phone: null,
  timezone: 'Africa/Cairo',
  default_language: 'ar',
  logo_file_id: null,
  tax_registration_no: null,
  receipt_header: null,
  receipt_footer: null,
  receipt_width_mm: 80,
  receipt_fields: {
    logo: true,
    address: true,
    phone: true,
    tax_registration_no: true,
    branch: true,
    cashier: true,
    customer: false,
  },
  prices_include_vat: true,
  default_tax_class_id: null,
  discount_caps: { CASHIER: 5 },
  return_policy_days: 14,
  purchase_approval_threshold: '25000.50',
  credit_limit_income_multiple: null,
  collector_commission_pct: '0.00',
  allow_negative_bank: false,
  theme_color: '#2563EB',
  currency: 'EGP',
  credit_min_score: 50,
  credit_score_weights: { guarantors: 40, income: 30, residence: 20, identity: 10 },
  legal_referral_days: { daily: 35, weekly: 63, monthly: 63 },
  customer_ban_days: 180,
  overdue_warning_interval_days: 10,
  global_min_stock: 3,
  updated_at: '2026-10-07T09:00:00.123456+00:00',
  updated_by: null,
  my_discount: { cap_pct: 5, above_cap_allowed: false },
  installment_policy: policy,
  tax_class_options: [],
};

function ctxWith(db: ReturnType<typeof createSupabaseMock>): RequestContext {
  return {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'OWNER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
}

describe('P03 settings service', () => {
  it('parses the settings with money and percentages as decimal strings', async () => {
    const db = createSupabaseMock();
    db.queue({ data: settings, error: null });
    const s = await getSettings(ctxWith(db));
    expect(db.rpc).toHaveBeenCalledWith('get_shop_settings');
    expect(s.purchase_approval_threshold).toBe('25000.50');
    expect(s.installment_policy?.min_sale_amount).toBe('2500.00');
  });

  it('refuses a settings payload whose money came back as a number', async () => {
    const db = createSupabaseMock();
    db.queue({ data: { ...settings, purchase_approval_threshold: 25000.5 }, error: null });
    await expect(getSettings(ctxWith(db))).rejects.toThrow();
  });

  it('sends only the changed fields, then reads the settings back', async () => {
    const db = createSupabaseMock();
    db.queue({ data: null, error: null }, { data: settings, error: null });
    await updateSettings(ctxWith(db), { discount_caps: { CASHIER: 5 } });
    expect(db.rpc).toHaveBeenNthCalledWith(1, 'update_org_settings', {
      p_changes: { discount_caps: { CASHIER: 5 } },
    });
    expect(db.rpc).toHaveBeenNthCalledWith(2, 'get_shop_settings');
  });

  it('returns the published version from the history', async () => {
    const db = createSupabaseMock();
    db.queue({ data: ID, error: null }, { data: [policy], error: null });
    expect((await publishPolicy(ctxWith(db), { grace_days: 3 })).version).toBe(2);
    expect(db.rpc).toHaveBeenNthCalledWith(1, 'publish_installment_policy', {
      p_policy: { grace_days: 3 },
    });
  });

  it.each([
    ['SETTINGS_INVALID', 400],
    ['POLICY_INVALID', 400],
    ['TAX_CLASS_NOT_FOUND', 404],
    ['DISCOUNT_ABOVE_CAP', 403],
    ['FILE_NOT_FOUND', 404],
    ['MODULE_NOT_IN_PLAN', 403],
  ] as const)('maps %s without the raw detail', (code, status) => {
    const err = mapDbError({ message: code + ': discount_caps.CASHIER' });
    expect(err).toMatchObject({ code, statusCode: status });
    expect(err?.message).not.toContain('discount_caps');
  });
});
