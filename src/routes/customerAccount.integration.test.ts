// R02 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// sells to one customer twice, once in cash and once by bank transfer (S02), through the real API;
// the account shows both purchases and the money in, the statement nets to 0 (everything is paid,
// no store credit), a contract that is not the customer's answers CONTRACT_NOT_FOUND, a bad range
// answers 400 and a WAREHOUSE user (no customer read key) gets 403.
import { beforeAll, describe, it, expect } from 'vitest';
import { randomUUID } from 'node:crypto';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CustomerAccount,
  CustomerStatement,
  ErrorResponse,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('R02 customer account against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let warehouse: string;
  let org: string;
  let branch: string;
  let chair: string;
  let customer: string;
  let ip = 0;
  let pos = '';
  const call = (
    method: 'get' | 'post',
    path: string,
    token = owner,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.74.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.74.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const key = (tag: string) => `r02-it-${tag}-${STAMP}`;

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `r02.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.74.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'R02 shop',
        tenant_slug: `r02-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.74.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;

    const warehouseEmail = `r02.warehouse.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: warehouseEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: warehouseEmail,
        full_name: 'Wael Warehouse',
        role: 'WAREHOUSE',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    warehouse = await login(warehouseEmail);

    const product = await call('post', '/api/products', owner, {
      name_ar: 'كرسي',
      sku: 'R02-CH',
      cash_price: '250.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    chair = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: chair, quantity: 5 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);

    const made = await call('post', '/api/customers', owner, {
      full_name: 'R02 Account Customer',
      phones: ['01000000474'],
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    customer = (made.body as { id: string }).id;
  }, 60_000);

  it('two paid sales show in the account and net to 0 on the statement', async () => {
    const shift = await call(
      'post',
      '/api/shifts',
      owner,
      { branch_id: branch, opening_float: '0' },
      key('shift'),
    );
    expect(shift.status, JSON.stringify(shift.body)).toBe(201);
    const bank = await call('post', '/api/cash-accounts', owner, {
      name: `R02 bank ${STAMP}`,
      kind: 'bank',
      branch_id: null,
    });
    expect(bank.status, JSON.stringify(bank.body)).toBe(201);
    const bankId = (bank.body as { id: string }).id;
    const lines = [{ product_id: chair, quantity: 1 }];
    const cash = await call(
      'post',
      '/api/sales',
      owner,
      { lines, expected_total: '250.00', customer_id: customer },
      key('cash-sale'),
    );
    expect(cash.status, JSON.stringify(cash.body)).toBe(201);
    const transfer = await call(
      'post',
      '/api/sales',
      owner,
      {
        lines,
        expected_total: '250.00',
        customer_id: customer,
        payments: [
          {
            method: 'bank_transfer',
            amount: '250.00',
            cash_account_id: bankId,
            reference: 'TRX-R02',
          },
        ],
      },
      key('bank-sale'),
    );
    expect(transfer.status, JSON.stringify(transfer.body)).toBe(201);

    const res = await call('get', `/api/customers/${customer}/account`);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    const account = CustomerAccount.parse(res.body);
    expect(account.totals).toMatchObject({
      purchases_count: 2,
      purchases_total: '500.00',
      payments_in: '500.00',
      payments_out: '0.00',
    });
    expect(account.balance).toMatchObject({
      open_balance: '0.00',
      total_due: '0.00',
      store_credit: '0.00',
    });
    expect(account.contracts).toEqual([]);
    expect(account.recent_payments.map((p) => [p.method, p.amount, p.reference])).toEqual(
      expect.arrayContaining([
        ['cash', '250.00', null],
        ['bank_transfer', '250.00', 'TRX-R02'],
      ]),
    );
    expect(account.recent_payments.every((p) => p.allocated_to[0]?.kind === 'sale')).toBe(true);

    const st = await call('get', `/api/customers/${customer}/statement`);
    expect(st.status, JSON.stringify(st.body)).toBe(200);
    const statement = CustomerStatement.parse(st.body);
    expect(statement.rows.map((r) => r.kind)).toEqual(['sale', 'payment_in', 'sale', 'payment_in']);
    expect(statement).toMatchObject({
      opening_balance: '0.00',
      closing_balance: '0.00',
      totals: { debit: '500.00', credit: '500.00' },
    });
    const today = statement.rows[0]!.date;
    const ranged = await call(
      'get',
      `/api/customers/${customer}/statement?from=${today}&to=${today}`,
    );
    expect(ranged.status).toBe(200);
    expect(CustomerStatement.parse(ranged.body).rows).toHaveLength(4);
  });

  it('refuses a contract that is not the customer’s, a bad range and a user without a read key', async () => {
    const schedule = await call(
      'get',
      `/api/customers/${customer}/contracts/${randomUUID()}/schedule`,
    );
    expect(schedule.status).toBe(404);
    expect(code(schedule)).toBe('CONTRACT_NOT_FOUND');
    const backwards = await call(
      'get',
      `/api/customers/${customer}/statement?from=2026-10-16&to=2026-10-15`,
    );
    expect(backwards.status).toBe(400);
    const tooLong = await call(
      'get',
      `/api/customers/${customer}/statement?from=2020-01-01&to=2026-01-01`,
    );
    expect(tooLong.status).toBe(400);
    const unknown = await call('get', `/api/customers/${randomUUID()}/account`);
    expect(unknown.status).toBe(404);
    expect(code(unknown)).toBe('CUSTOMER_NOT_FOUND');
    for (const path of [
      `/api/customers/${customer}/account`,
      `/api/customers/${customer}/statement`,
      `/api/customers/${customer}/contracts/${randomUUID()}/schedule`,
    ]) {
      const denied = await call('get', path, warehouse);
      expect(denied.status, path).toBe(403);
      expect(code(denied)).toBe('PERMISSION_DENIED');
    }
  });
});
