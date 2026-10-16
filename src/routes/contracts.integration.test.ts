// N02 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// publishes an installment policy and stocks TVs; a cashier opens a shift and sells one on
// installments with a cash down payment (two requests with one key: one sale, one contract); the
// down payment is in the drawer; the contract reads back with its schedule; a customer without a
// national ID, an old policy version, a warehouse user and an unknown contract are refused.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  Contract,
  ErrorResponse,
  InstallmentSale,
  Shift,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('N02 installment sale and contract against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let warehouse: string;
  let org: string;
  let branch: string;
  let tv: string;
  let customerId: string;
  let noIdCustomer: string;
  let shift: Shift;
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
      .set('X-Forwarded-For', `198.18.77.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `n02-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.77.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'CASHIER' | 'WAREHOUSE', tag: string) {
    const email = `n02.${tag}.${STAMP}@ecotech.test`;
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
        full_name: `N02 ${tag}`,
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
  async function newCustomer(tag: string, nationalId?: string) {
    const created = await call('post', '/api/customers', owner, {
      full_name: `N02 ${tag} ${STAMP}`,
      phones: ['01500000077'],
      ...(nationalId ? { national_id: nationalId } : {}),
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const id = (created.body as { id: string }).id;
    const limit = await call('put', `/api/customers/${id}/credit-limit`, owner, {
      credit_limit: '100000.00',
      reason: 'N02 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
    return id;
  }
  const sale = (customer: string, version = 1) => ({
    lines: [{ product_id: tv, quantity: 1 }],
    expected_total: '12000.00',
    customer_id: customer,
    terms: {
      down_payment: '2000.00',
      installments_count: 12,
      frequency: 'monthly',
      policy_version: version,
    },
  });

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `n02.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.77.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'N02 shop',
        tenant_slug: `n02-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.77.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;
    cashier = await addEmployee('CASHIER', 'cashier');
    warehouse = await addEmployee('WAREHOUSE', 'warehouse');

    const settings = await call('patch', '/api/settings', owner, {
      prices_include_vat: true,
      credit_min_score: 0,
    });
    expect(settings.status, JSON.stringify(settings.body)).toBe(200);
    const published = await call('post', '/api/settings/installment-policies', owner, {
      min_down_payment_pct: '10',
      max_months: 24,
      markup_tiers: [
        { up_to_months: 6, pct: 10 },
        { up_to_months: 24, pct: 20 },
      ],
      allowed_frequencies: ['monthly'],
      rounding_step: '1.00',
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: `N02-TV-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: tv, quantity: 5 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    customerId = await newCustomer('customer', '29001010100776');
    noIdCustomer = await newCustomer('no-id');
    const opened = await call(
      'post',
      '/api/shifts',
      cashier,
      { branch_id: branch, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    shift = Shift.parse(opened.body);
  }, 120_000);

  it('sells on installments once for one key; the contract adds up and reads back', async () => {
    const first = await call(
      'post',
      '/api/installments/sales',
      cashier,
      sale(customerId),
      key('sale'),
    );
    expect(first.status, JSON.stringify(first.body)).toBe(201);
    const answer = InstallmentSale.parse(first.body);
    expect(answer.sale.total).toBe('12000.00');
    expect(answer.contract).toMatchObject({
      status: 'active',
      cash_price: '12000.00',
      down_payment: '2000.00',
      financed_amount: '10000.00',
      markup_amount: '2000.00',
      total_payable: '12000.00',
      installments_count: 12,
    });
    expect(answer.contract.lines).toHaveLength(12);
    expect(answer.sale.payments.map((p) => [p.method, p.amount])).toEqual([['cash', '2000.00']]);

    const again = await call(
      'post',
      '/api/installments/sales',
      cashier,
      sale(customerId),
      key('sale'),
    );
    expect(again.status, JSON.stringify(again.body)).toBe(201);
    expect(InstallmentSale.parse(again.body).contract.id).toBe(answer.contract.id);
    const contracts = await service.from('contracts').select('id').eq('organization_id', org);
    expect(contracts.data).toHaveLength(1);

    const drawer = await service
      .from('cash_movements')
      .select('amount')
      .eq('shift_id', shift.id)
      .eq('source_id', answer.sale.id);
    expect(drawer.data?.map((m) => String(m.amount))).toEqual(['2000.00']);

    const read = await call('get', `/api/contracts/${answer.contract.id}`, owner);
    expect(read.status, JSON.stringify(read.body)).toBe(200);
    expect(Contract.parse(read.body).balance.remaining).toBe('12000.00');
  });

  it('refuses a customer without a national ID, an old policy version and a warehouse user', async () => {
    const noId = await call('post', '/api/installments/sales', cashier, sale(noIdCustomer));
    expect(noId.status).toBe(409);
    expect(code(noId)).toBe('CUSTOMER_NATIONAL_ID_REQUIRED');

    const old = await call(
      'post',
      '/api/installments/sales',
      cashier,
      sale(customerId, 9),
      key('old'),
    );
    expect(old.status).toBe(409);
    expect(code(old)).toBe('POLICY_CHANGED');

    const denied = await call(
      'post',
      '/api/installments/sales',
      warehouse,
      sale(customerId),
      key('warehouse'),
    );
    expect(denied.status).toBe(403);

    const bad = await call(
      'post',
      '/api/installments/sales',
      cashier,
      { ...sale(customerId), organization_id: org },
      key('bad'),
    );
    expect(bad.status).toBe(400);
  });

  it('answers CONTRACT_NOT_FOUND for an unknown contract', async () => {
    const res = await call('get', '/api/contracts/00000000-0000-4000-8000-00000000c0de', owner);
    expect(res.status).toBe(404);
    expect(code(res)).toBe('CONTRACT_NOT_FOUND');
  });
});
