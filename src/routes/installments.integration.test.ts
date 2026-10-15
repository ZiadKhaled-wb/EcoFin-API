// N01 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// publishes an installment policy; a cashier previews an installment sale without and with a
// customer (credit, guarantors, survey and can_confirm); a broken rule is answered, not raised; a
// warehouse user, a bad body, an unknown customer and a shop with installments off are refused.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuthLoginResponse, ErrorResponse, InstallmentPreview } from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const BODY = {
  cash_price: '14000.00',
  down_payment: '2000.00',
  installments_count: 12,
  frequency: 'monthly',
};

describe.skipIf(!RUN)('N01 installment terms preview against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let admin: string;
  let owner: string;
  let cashier: string;
  let warehouse: string;
  let org: string;
  let customerId: string;
  let ip = 0;
  const nextIp = () => `198.18.76.${(++ip % 250) + 1}`;
  const call = (method: 'post' | 'put' | 'patch', path: string, token: string, body?: object) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    return body ? r.send(body) : r;
  };
  const preview = (token: string, body: object) =>
    call('post', '/api/installments/preview', token, body);
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'CASHIER' | 'WAREHOUSE', tag: string, branchId: string) {
    const email = `n01.${tag}.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email,
        full_name: `N01 ${tag}`,
        role,
        default_branch_id: branchId,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branchId });
    return login(email);
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    admin = await login('superadmin@ecotech.test');
    const email = `n01.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'N01 main',
        tenant_slug: `n01-main-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', nextIp())
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    org = shop.body.organization_id as string;
    owner = await login(email);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    cashier = await addEmployee('CASHIER', 'cashier', main.data!.id);
    warehouse = await addEmployee('WAREHOUSE', 'warehouse', main.data!.id);

    const published = await call('post', '/api/settings/installment-policies', owner, {
      min_down_payment_pct: '10',
      max_months: 24,
      markup_tiers: [
        { up_to_months: 6, pct: 10 },
        { up_to_months: 24, pct: 20 },
      ],
      allowed_frequencies: ['monthly', 'weekly'],
      rounding_step: '1.00',
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    const settings = await call('patch', '/api/settings', owner, { credit_min_score: 0 });
    expect(settings.status, JSON.stringify(settings.body)).toBe(200);
    const customer = await call('post', '/api/customers', owner, {
      full_name: `N01 customer ${STAMP}`,
      phones: ['01500000076'],
    });
    expect(customer.status, JSON.stringify(customer.body)).toBe(201);
    customerId = (customer.body as { id: string }).id;
    const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '50000.00',
      reason: 'N01 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
  }, 120_000);

  it('a cashier previews the terms: whole-term profit, 12 equal installments, no customer', async () => {
    const res = await preview(cashier, BODY);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    const p = InstallmentPreview.parse(res.body);
    expect(p.terms).toMatchObject({
      financed_amount: '12000.00',
      markup_pct: '20',
      markup_amount: '2400.00',
      total_payable: '14400.00',
      installment_amount: '1200.00',
      violations: [],
    });
    expect(p.terms.lines).toHaveLength(12);
    expect(p.customer).toBeNull();
    expect(p.can_confirm).toBe(false);
  });

  it('with the customer the credit, guarantor and survey answers are added and it can confirm', async () => {
    const res = await preview(cashier, { ...BODY, customer_id: customerId });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    const p = InstallmentPreview.parse(res.body);
    expect(p.customer?.credit.allowed).toBe(true);
    expect(p.customer?.guarantors).toMatchObject({
      required_count: 0,
      selected: 0,
      selected_met: true,
    });
    expect(p.customer?.survey.met).toBe(true);
    expect(p.can_confirm).toBe(true);
  });

  it('a broken rule is answered with its details, not raised', async () => {
    const res = await preview(cashier, { ...BODY, down_payment: '0.00', frequency: 'daily' });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    const p = InstallmentPreview.parse(res.body);
    expect(p.terms.violations.map((v) => v.rule)).toEqual([
      'frequency_not_allowed',
      'down_payment_too_low',
    ]);
    expect(p.can_confirm).toBe(false);
  });

  it('refuses a warehouse user, a bad body, an unknown customer and a shop with installments off', async () => {
    const denied = await preview(warehouse, BODY);
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    const bad = await preview(cashier, { ...BODY, installments_count: 521 });
    expect(bad.status).toBe(400);
    expect(code(bad)).toBe('VALIDATION_FAILED');
    const unknown = await preview(cashier, {
      ...BODY,
      customer_id: '00000000-0000-4000-8000-0000000000c9',
    });
    expect(unknown.status).toBe(404);
    expect(code(unknown)).toBe('CUSTOMER_NOT_FOUND');
    const off = await call('patch', '/api/settings/profile', owner, {
      installments_enabled: false,
    });
    expect(off.status, JSON.stringify(off.body)).toBe(200);
    const disabled = await preview(cashier, BODY);
    expect(disabled.status).toBe(403);
    expect(code(disabled)).toBe('INSTALLMENTS_DISABLED');
  });
});
