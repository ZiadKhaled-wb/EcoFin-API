// N04 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// sells a TV on installments (N02). Over HTTP: the overdue lists answer (a cashier is refused), the
// owner's manual check runs, a policy with a late fee is refused (rule 4) and one without is saved,
// a warning is handled once (a second time is refused with its status), a legal referral is
// dismissed by the owner only. The nightly job function runs for the shop and changes nothing that
// is owed. (The lateness rules themselves: supabase/tests/n04_overdue_tracking_test.sql, where the
// due dates can be moved back.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  InstallmentSale,
  OverdueAction,
  OverdueActionPage,
  OverdueListPage,
  OverdueRunResult,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('N04 overdue tracking against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let manager: string;
  let org: string;
  let branch: string;
  let tv: string;
  let customerId: string;
  let version: number;
  let sale: InstallmentSale;
  let ip = 0;
  let pos = '';
  const call = (
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    token: string,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.79.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `n04-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.79.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'CASHIER' | 'BRANCH_MANAGER', tag: string) {
    const email = `n04.${tag}.${STAMP}@ecotech.test`;
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
        full_name: `N04 ${tag}`,
        role,
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    return login(email);
  }
  /** An open warning or legal referral on the contract (the check needs a late contract). */
  async function action(kind: 'warning' | 'legal_referral') {
    const line = await service
      .from('schedule_lines')
      .select('id')
      .eq('contract_id', sale.contract.id)
      .order('seq')
      .limit(1)
      .single();
    expect(line.error).toBeNull();
    const made = await service
      .from('overdue_actions')
      .insert({
        organization_id: org,
        kind,
        contract_id: sale.contract.id,
        customer_id: customerId,
        branch_id: branch,
        schedule_line_id: (line.data as { id: string }).id,
        business_date: new Date().toISOString().slice(0, 10),
        days_late: 5,
        overdue_amount: '1000.00',
        status: 'open',
      })
      .select('id')
      .single();
    expect(made.error).toBeNull();
    return (made.data as { id: string }).id;
  }
  async function owed() {
    const { data, error } = await service
      .from('v_contract_balances')
      .select('total_payable, paid, remaining')
      .eq('contract_id', sale.contract.id)
      .single();
    expect(error).toBeNull();
    return data;
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `n04.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.79.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'N04 shop',
        tenant_slug: `n04-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.79.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;
    cashier = await addEmployee('CASHIER', 'cashier');
    manager = await addEmployee('BRANCH_MANAGER', 'manager');

    const settings = await call('patch', '/api/settings', owner, {
      prices_include_vat: true,
      credit_min_score: 0,
    });
    expect(settings.status, JSON.stringify(settings.body)).toBe(200);
    const published = await call('post', '/api/settings/installment-policies', owner, {
      min_down_payment_pct: '10',
      max_months: 24,
      markup_tiers: [{ up_to_months: 24, pct: 20 }],
      allowed_frequencies: ['monthly'],
      rounding_step: '1.00',
      grace_days: 3,
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    const current = await call('get', '/api/settings', owner);
    version = (current.body as { installment_policy: { version: number } }).installment_policy
      .version;
    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: `N04-TV-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: tv, quantity: 2 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const created = await call('post', '/api/customers', owner, {
      full_name: `N04 customer ${STAMP}`,
      phones: ['01500000079'],
      national_id: '29001010100779',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    customerId = (created.body as { id: string }).id;
    const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '100000.00',
      reason: 'N04 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
    const opened = await call(
      'post',
      '/api/shifts',
      cashier,
      { branch_id: branch, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    const sold = await call(
      'post',
      '/api/installments/sales',
      cashier,
      {
        lines: [{ product_id: tv, quantity: 1 }],
        expected_total: '12000.00',
        customer_id: customerId,
        terms: {
          down_payment: '2000.00',
          installments_count: 12,
          frequency: 'monthly',
          policy_version: version,
        },
      },
      key('sale'),
    );
    expect(sold.status, JSON.stringify(sold.body)).toBe(201);
    sale = InstallmentSale.parse(sold.body);
  }, 120_000);

  it('lists overdue contracts, warnings and referrals; a cashier is refused', async () => {
    const list = await call('get', '/api/overdue?min_days=1&limit=10', manager);
    expect(list.status, JSON.stringify(list.body)).toBe(200);
    const page = OverdueListPage.parse(list.body);
    expect(page.items).toHaveLength(0); // the contract is not late
    expect(page.totals.overdue_amount).toBe('0.00');
    for (const path of ['/api/overdue/warnings?status=all', '/api/overdue/legal-referrals']) {
      const r = await call('get', path, manager);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      OverdueActionPage.parse(r.body);
    }
    const refused = await call('get', '/api/overdue', cashier);
    expect(refused.status).toBe(403);
    expect(code(refused)).toBe('PERMISSION_DENIED');
    const bad = await call('get', '/api/overdue?collector_id=x', manager);
    expect(bad.status).toBe(400);
  });

  it('the owner runs the check by hand (twice: nothing new); a manager is refused', async () => {
    const before = await owed();
    const first = await call('post', '/api/overdue/run', owner);
    expect(first.status, JSON.stringify(first.body)).toBe(200);
    OverdueRunResult.parse(first.body);
    const again = OverdueRunResult.parse((await call('post', '/api/overdue/run', owner)).body);
    expect(again).toMatchObject({
      warnings_created: 0,
      warnings_resolved: 0,
      bans: 0,
      customers_blocked: 0,
      legal_referrals: 0,
    });
    const refused = await call('post', '/api/overdue/run', manager);
    expect(refused.status).toBe(403);
    expect(await owed()).toEqual(before);
  });

  it('the nightly job function runs for the shop and never changes what is owed', async () => {
    const before = await owed();
    const { data, error } = await service.rpc('jobs_overdue_run', { p_organization_id: org });
    expect(error).toBeNull();
    OverdueRunResult.parse(data);
    expect(await owed()).toEqual(before);
  });

  it('a policy with a late fee is refused; without one it is saved with no fee (rule 4)', async () => {
    const fee = await call('post', '/api/settings/installment-policies', owner, {
      late_fee_type: 'fixed',
      late_fee_value: '50.00',
    });
    expect(fee.status).toBe(422);
    expect(code(fee)).toBe('LATE_FEES_NOT_ALLOWED');
    const none = await call('post', '/api/settings/installment-policies', owner, {
      late_fee_type: 'none',
      late_fee_value: '0.00',
      grace_days: 5,
    });
    expect(none.status, JSON.stringify(none.body)).toBe(201);
    const current = await call('get', '/api/settings', owner);
    expect(
      (current.body as { installment_policy: { late_fee_type: string; grace_days: number } })
        .installment_policy,
    ).toMatchObject({ late_fee_type: 'none', grace_days: 5 });
  });

  it('a warning is handled once; the second time answers its status', async () => {
    const id = await action('warning');
    const listed = OverdueActionPage.parse(
      (await call('get', '/api/overdue/warnings', manager)).body,
    );
    expect(listed.items.map((w) => w.id)).toContain(id);
    const noNote = await call('post', `/api/overdue/warnings/${id}/handle`, manager, {
      outcome: 'other',
    });
    expect(noNote.status).toBe(400);
    const handled = await call('post', `/api/overdue/warnings/${id}/handle`, manager, {
      outcome: 'promised',
      note: 'Will pay on Thursday',
    });
    expect(handled.status, JSON.stringify(handled.body)).toBe(200);
    expect(OverdueAction.parse(handled.body)).toMatchObject({
      status: 'handled',
      outcome: 'promised',
      handled_by_name: 'N04 manager',
    });
    const twice = await call('post', `/api/overdue/warnings/${id}/handle`, manager, {
      outcome: 'contacted',
    });
    expect(twice.status).toBe(409);
    expect(ErrorResponse.parse(twice.body).error).toMatchObject({
      code: 'OVERDUE_ACTION_NOT_OPEN',
      details: { status: 'handled' },
    });
    const cashierTry = await call('post', `/api/overdue/warnings/${id}/handle`, cashier, {
      outcome: 'contacted',
    });
    expect(cashierTry.status).toBe(403);
  });

  it('a legal referral is dismissed by the owner only, with a reason', async () => {
    const id = await action('legal_referral');
    const byManager = await call('post', `/api/overdue/legal-referrals/${id}/dismiss`, manager, {
      reason: 'Paid at the office',
    });
    expect(byManager.status).toBe(403);
    expect(code(byManager)).toBe('PERMISSION_DENIED');
    const short = await call('post', `/api/overdue/legal-referrals/${id}/dismiss`, owner, {
      reason: 'no',
    });
    expect(short.status).toBe(400);
    const dismissed = await call('post', `/api/overdue/legal-referrals/${id}/dismiss`, owner, {
      reason: 'Agreed a payment plan',
    });
    expect(dismissed.status, JSON.stringify(dismissed.body)).toBe(200);
    expect(OverdueAction.parse(dismissed.body)).toMatchObject({
      kind: 'legal_referral',
      status: 'dismissed',
      note: 'Agreed a payment plan',
    });
    const all = OverdueActionPage.parse(
      (await call('get', '/api/overdue/legal-referrals?status=all', manager)).body,
    );
    expect(all.items.find((r) => r.id === id)?.status).toBe('dismissed');
  });
});
