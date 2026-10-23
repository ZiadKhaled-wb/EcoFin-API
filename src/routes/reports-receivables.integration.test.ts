// D03 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop sells a TV
// on installments and takes a first payment through the API; the receivables aging for that customer equals the
// customer page's open balance, its drill-down lists the contract, its self-check passes, and a cashier (no
// report.financial) is refused. (Every bucket, grouping, filter and edge: supabase/tests/d03_receivables_aging_test.sql;
// the clock can't move here, so every line is still not due.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CustomerAccount,
  ErrorResponse,
  ReceivablesReport,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('D03 receivables aging against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let clerk: string;
  let org: string;
  let main: string;
  let tv: string;
  let customerId: string;
  let version: number;
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
      .set('X-Forwarded-For', `198.18.89.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `d03-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.89.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const report = async (token: string, query: string) => {
    const res = await call('get', '/api/reports/receivables?' + query, token);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return ReceivablesReport.parse(res.body);
  };

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `d03.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.89.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'D03 shop',
        tenant_slug: `d03-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.89.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const branch = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(branch.error).toBeNull();
    main = branch.data!.id as string;
    pos = (await pairTestDevice(service, org, main)).token;

    // A cashier: no report.financial.
    const clerkEmail = `d03.clerk.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: clerkEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: clerkEmail,
        full_name: 'D03 clerk',
        role: 'CASHIER',
        default_branch_id: main,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: main });
    clerk = await login(clerkEmail);

    expect(
      (
        await call('patch', '/api/settings', owner, {
          prices_include_vat: true,
          credit_min_score: 0,
        })
      ).status,
    ).toBe(200);
    const published = await call('post', '/api/settings/installment-policies', owner, {
      min_down_payment_pct: '10',
      max_months: 24,
      markup_tiers: [{ up_to_months: 24, pct: 20 }],
      allowed_frequencies: ['monthly'],
      rounding_step: '1.00',
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    const current = await call('get', '/api/settings', owner);
    version = (current.body as { installment_policy: { version: number } }).installment_policy
      .version;
    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: `D03-TV-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: main, reason: 'found', lines: [{ product_id: tv, quantity: 2 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const created = await call('post', '/api/customers', owner, {
      full_name: `D03 customer ${STAMP}`,
      phones: ['01500000089'],
      national_id: '29001010100789',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    customerId = (created.body as { id: string }).id;
    const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '100000.00',
      reason: 'D03 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
  }, 120_000);

  it('equals the customer page after an installment sale and a first payment', async () => {
    const opened = await call(
      'post',
      '/api/shifts',
      owner,
      { branch_id: main, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    const sale = await call(
      'post',
      '/api/installments/sales',
      owner,
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
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
    const contractId = (sale.body as { contract: { id: string } }).contract.id;
    const paid = await call(
      'post',
      '/api/collections',
      owner,
      {
        customer_id: customerId,
        contracts: [{ contract_id: contractId, amount: '500.00' }],
        payments: [{ method: 'cash', amount: '500.00' }],
      },
      key('collect'),
    );
    expect(paid.status, JSON.stringify(paid.body)).toBe(201);

    const account = await call('get', `/api/customers/${customerId}/account`, owner);
    expect(account.status, JSON.stringify(account.body)).toBe(200);
    const balance = CustomerAccount.parse(account.body).balance;

    const byCustomer = await report(owner, 'group_by=customer');
    const row = byCustomer.rows.find((r) => r.key === customerId);
    expect(row).toMatchObject({
      outstanding: balance.open_balance,
      not_due: balance.open_balance,
      overdue: '0.00',
      contracts: 1,
      customers: 1,
      customer: { id: customerId },
    });
    expect(balance.open_balance).toBe('11500.00');
    expect(row?.last_payment_at).not.toBeNull();
    expect(byCustomer.totals.outstanding).toBe('11500.00');
    expect(byCustomer.check.rows_match).toBe(true);
    expect(byCustomer.check.contracts_checked).toBe(1);

    const drill = await report(owner, `group_by=contract&customer_id=${customerId}`);
    expect(drill.rows.map((r) => r.key)).toEqual([contractId]);
    expect(drill.rows[0]).toMatchObject({
      outstanding: '11500.00',
      contract: { id: contractId, status: 'active', is_migrated: false },
      branch: { id: main },
    });
    expect(drill.check.rows_match).toBe(true);
    const byBranch = await report(owner, `group_by=branch&branch_id=${main}`);
    expect(byBranch.rows.map((r) => [r.key, r.outstanding])).toEqual([[main, '11500.00']]);
    const none = await report(owner, 'group_by=collector&collector_id=none');
    expect(none.rows.map((r) => [r.key, r.label, r.outstanding])).toEqual([
      ['none', null, '11500.00'],
    ]);
  });

  it('refuses a cashier without report.financial, bad queries and an org id', async () => {
    const denied = await call('get', '/api/reports/receivables?group_by=customer', clerk);
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    for (const query of [
      'group_by=product',
      'group_by=branch&q=amal',
      'group_by=customer&collector_id=all',
      'group_by=customer&min_days=0',
      `group_by=customer&organization_id=${org}`,
    ]) {
      const bad = await call('get', '/api/reports/receivables?' + query, owner);
      expect(bad.status, query).toBe(400);
      expect(code(bad), query).toBe('VALIDATION_FAILED');
    }
  });
});
