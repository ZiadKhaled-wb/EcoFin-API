// P03 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh
// shop's owner edits settings and publishes installment policy versions; a cashier reads the
// settings (own discount cap) and is refused every write.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  InstallmentPolicy,
  InstallmentPolicyList,
  ShopSettings,
  TaxClass,
  TaxClassList,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('P03 settings against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let org: string;
  let ip = 0;
  const call = (method: 'get' | 'post' | 'patch', path: string, token = owner, body?: object) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.11.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.11.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `p03.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.11.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'P03 shop',
        tenant_slug: `p03-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.11.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    const cashierEmail = `p03.cashier.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: cashierEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: cashierEmail,
        full_name: 'Cashier',
        role: 'CASHIER',
        default_branch_id: main.data!.id,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: main.data!.id });
    cashier = await login(cashierEmail);
  });

  it('a new shop starts with the P01 defaults and policy version 1', async () => {
    const r = await call('get', '/api/settings');
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const s = ShopSettings.parse(r.body);
    expect(s.name).toBe('P03 shop');
    expect(s.currency).toBe('EGP');
    expect(s.receipt_fields.customer).toBe(true);
    expect(s.installment_policy?.version).toBe(1);
    expect(s.my_discount).toEqual({ cap_pct: 100, above_cap_allowed: true });
  });

  it('owner changes several tabs at once; the cashier sees the new discount cap', async () => {
    const r = await call('patch', '/api/settings', owner, {
      address: 'Nasr City, Cairo',
      receipt_fields: { customer: false },
      receipt_width_mm: 58,
      discount_caps: { CASHIER: 5, BRANCH_MANAGER: 15 },
      credit_score_weights: { guarantors: 50, income: 30, residence: 10, identity: 10 },
      legal_referral_days: { weekly: 49 },
      purchase_approval_threshold: '25000.50',
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const s = ShopSettings.parse(r.body);
    expect(s.receipt_fields).toMatchObject({ customer: false, logo: true });
    expect(s.legal_referral_days).toEqual({ daily: 35, weekly: 49, monthly: 63 });
    expect(s.purchase_approval_threshold).toBe('25000.50');

    const asCashier = ShopSettings.parse((await call('get', '/api/settings', cashier)).body);
    expect(asCashier.my_discount).toEqual({ cap_pct: 5, above_cap_allowed: false });
    await call('patch', '/api/settings', owner, { discount_caps: { CASHIER: 10 } });
    const raised = ShopSettings.parse((await call('get', '/api/settings', cashier)).body);
    expect(raised.my_discount.cap_pct).toBe(10);
  });

  it('refuses bad values with contract error codes', async () => {
    const weights = await call('patch', '/api/settings', owner, {
      credit_score_weights: { guarantors: 50, income: 30, residence: 10, identity: 5 },
    });
    expect(weights.status).toBe(400);
    expect(code(weights)).toBe('VALIDATION_FAILED');
    const zone = await call('patch', '/api/settings', owner, { timezone: 'Mars/Base' });
    expect(zone.status).toBe(400);
    expect(code(zone)).toBe('SETTINGS_INVALID');
    const tax = await call('patch', '/api/settings', owner, {
      default_tax_class_id: 'a0300000-0000-4000-8000-0000000000ff',
    });
    expect(tax.status).toBe(404);
    expect(code(tax)).toBe('TAX_CLASS_NOT_FOUND');
  });

  it('publishing a policy creates a new version and leaves the old one as it was', async () => {
    const r = await call('post', '/api/settings/installment-policies', owner, {
      min_down_payment_pct: '10',
      max_down_payment_pct: '50',
      max_months: 15,
      allowed_frequencies: ['monthly', 'daily'],
      down_payment_rules: { monthly: 'one_installment', daily: 'installment_per_day_of_month' },
      min_installment_by_frequency: { daily: '50.00', monthly: '500.00' },
      amount_tiers: [
        { up_to_amount: '100000.00', max_months: 10 },
        { up_to_amount: '1000000.00', max_months: 15 },
      ],
      markup_tiers: [{ up_to_months: 15, pct: 25 }],
      min_sale_amount: '2500.00',
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const v2 = InstallmentPolicy.parse(r.body);
    expect(v2.version).toBe(2);
    expect(v2.min_down_payment_pct).toBe('10.00');

    const again = await call('post', '/api/settings/installment-policies', owner, {
      grace_days: v2.grace_days,
    });
    expect(InstallmentPolicy.parse(again.body).id).toBe(v2.id);

    const history = InstallmentPolicyList.parse(
      (await call('get', '/api/settings/installment-policies')).body,
    );
    expect(history.map((p) => p.version)).toEqual([2, 1]);
    expect(history[1]?.max_months).toBe(12);
    const s = ShopSettings.parse((await call('get', '/api/settings')).body);
    expect(s.installment_policy?.id).toBe(v2.id);

    const bad = await call('post', '/api/settings/installment-policies', owner, {
      down_payment_rules: { monthly: 'installment_per_day_of_month' },
    });
    expect(bad.status).toBe(400);
    expect(code(bad)).toBe('POLICY_INVALID');
  });

  it('T01: tax classes start with the three defaults; the owner manages them, the cashier reads', async () => {
    const list = TaxClassList.parse((await call('get', '/api/tax-classes')).body);
    expect(list.map((c) => [c.kind, c.rate]).sort()).toEqual([
      ['exempt', '0.00'],
      ['standard', '14.00'],
      ['zero', '0.00'],
    ]);
    const standard = list.find((c) => c.kind === 'standard')!;
    const s = ShopSettings.parse((await call('get', '/api/settings')).body);
    expect(s.default_tax_class_id).toBe(standard.id);
    expect(s.delivery_fee_tax_class_id).toBe(standard.id);
    expect(s.installment_markup_vat).toBe('not_taxed');

    const created = await call('post', '/api/tax-classes', owner, {
      name: 'Reduced 5%',
      kind: 'standard',
      rate: '5',
      eta_tax_type: 'T1',
      eta_subtype: 'V010',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const reduced = TaxClass.parse(created.body);
    expect(reduced.rate).toBe('5.00');
    const updated = await call('patch', `/api/tax-classes/${reduced.id}`, owner, { rate: '7.5' });
    expect(TaxClass.parse(updated.body).rate).toBe('7.50');
    const inUse = await call('post', `/api/tax-classes/${standard.id}/archive`);
    expect(inUse.status).toBe(409);
    expect(code(inUse)).toBe('TAX_CLASS_IN_USE');
    const taken = await call('post', '/api/tax-classes', owner, {
      name: 'Reduced 5%',
      kind: 'standard',
      rate: '5',
      eta_tax_type: 'T1',
      eta_subtype: 'V010',
    });
    expect(code(taken)).toBe('TAX_CLASS_NAME_TAKEN');
    expect((await call('get', '/api/tax-classes', cashier)).status).toBe(200);
    const denied = await call('post', `/api/tax-classes/${reduced.id}/archive`, cashier);
    expect(denied.status).toBe(403);
  });

  it('the cashier is refused every settings write and the policy history', async () => {
    for (const [method, path, body] of [
      ['patch', '/api/settings', { name: 'Cashier shop' }],
      ['get', '/api/settings/installment-policies', undefined],
      ['post', '/api/settings/installment-policies', { grace_days: 9 }],
    ] as const) {
      const r = await call(method, path, cashier, body);
      expect(r.status, `${method} ${path}`).toBe(403);
      expect(code(r)).toBe('PERMISSION_DENIED');
    }
    const s = ShopSettings.parse((await call('get', '/api/settings')).body);
    expect(s.name).toBe('P03 shop');
  });
});
