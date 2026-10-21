// D01 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// with two branches sells, voids a sale, sells on installments and collects through the API; the
// dashboard's numbers equal the HTTP detail routes for the same filters (sales history, the day
// close preview, shifts, cash accounts, overdue, low stock) for all branches and for each branch;
// a cashier sees only the tiles their keys open. (Every rule and edge: supabase/tests/d01_owner_dashboard_test.sql.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  DayClosePreview,
  ErrorResponse,
  OwnerDashboard,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

// Test-only decimal helper: whole cents, so the comparison is exact.
const cents = (money: string) => Math.round(Number(money) * 100);
const money = (c: number) => `${Math.trunc(c / 100)}.${String(Math.abs(c % 100)).padStart(2, '0')}`;

describe.skipIf(!RUN)('D01 owner dashboard against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let org: string;
  let main: string;
  let second: string;
  let chair: string;
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
      .set('X-Forwarded-For', `198.18.87.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `d01-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.87.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function today() {
    const { data, error } = await service
      .from('organizations')
      .select('timezone')
      .eq('id', org)
      .single();
    expect(error).toBeNull();
    return new Intl.DateTimeFormat('en-CA', { timeZone: data!.timezone as string }).format(
      new Date(),
    );
  }
  const dashboard = async (token: string, branch?: string) => {
    const res = await call('get', '/api/dashboard' + (branch ? `?branch_id=${branch}` : ''), token);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return OwnerDashboard.parse(res.body);
  };
  const items = (body: unknown) =>
    (Array.isArray(body) ? body : (body as { items: unknown[] }).items) as Record<
      string,
      unknown
    >[];

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `d01.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.87.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'D01 shop',
        tenant_slug: `d01-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.87.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const branch = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(branch.error).toBeNull();
    main = branch.data!.id as string;
    pos = (await pairTestDevice(service, org, main)).token;

    const made = await call('post', '/api/branches', owner, { name: 'Second', code: 'S2' });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    second = (made.body as { id: string }).id;

    const cashierEmail = `d01.cashier.${STAMP}@ecotech.test`;
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
        full_name: 'D01 Cashier',
        role: 'CASHIER',
        default_branch_id: main,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: main });
    cashier = await login(cashierEmail);

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
    const p1 = await call('post', '/api/products', owner, {
      name_ar: 'كرسي',
      sku: `D01-CH-${STAMP}`,
      cash_price: '250.00',
      min_stock: 5,
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    chair = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: `D01-TV-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    tv = (p2.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      {
        branch_id: main,
        reason: 'found',
        lines: [
          { product_id: chair, quantity: 8 },
          { product_id: tv, quantity: 3 },
        ],
      },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const created = await call('post', '/api/customers', owner, {
      full_name: `D01 customer ${STAMP}`,
      phones: ['01500000087'],
      national_id: '29001010100787',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    customerId = (created.body as { id: string }).id;
    const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '100000.00',
      reason: 'D01 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
  }, 120_000);

  it('equals the detail routes after a shop sells, voids, sells on installments and collects', async () => {
    const date = await today();
    const opened = await call(
      'post',
      '/api/shifts',
      owner,
      { branch_id: main, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    const sell = async (tag: string, product: string, quantity: number, total: string) => {
      const res = await call(
        'post',
        '/api/sales',
        owner,
        { lines: [{ product_id: product, quantity }], expected_total: total },
        key(tag),
      );
      expect(res.status, JSON.stringify(res.body)).toBe(201);
      return (res.body as { id: string }).id;
    };
    await sell('sale-1', chair, 2, '500.00');
    const voided = await sell('sale-2', chair, 1, '250.00');
    const void1 = await call(
      'post',
      `/api/sales/${voided}/void`,
      owner,
      { reason: 'Customer changed mind' },
      key('void'),
    );
    expect(void1.status, JSON.stringify(void1.body)).toBe(201);
    const inst = await call(
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
      key('inst'),
    );
    expect(inst.status, JSON.stringify(inst.body)).toBe(201);
    const contractId = (inst.body as { contract: { id: string } }).contract.id;
    const collected = await call(
      'post',
      '/api/collections',
      owner,
      {
        customer_id: customerId,
        contracts: [{ contract_id: contractId, amount: '1000.00' }],
        payments: [{ method: 'cash', amount: '1000.00' }],
      },
      key('collect'),
    );
    expect(collected.status, JSON.stringify(collected.body)).toBe(201);

    const all = await dashboard(owner);
    const inMain = await dashboard(owner, main);
    const inSecond = await dashboard(owner, second);
    expect(all.business_date).toBe(date);
    expect(all.branch_id).toBeNull();
    expect(inMain.branch_id).toBe(main);

    // Sales: the sales history of today, without the voided sale.
    const history = await call('get', `/api/sales?from=${date}&to=${date}&page_size=100`, owner);
    expect(history.status, JSON.stringify(history.body)).toBe(200);
    const sold = items(history.body).filter((s) => s['status'] !== 'voided');
    expect(items(history.body).some((s) => s['status'] === 'voided')).toBe(true);
    expect(all.tiles.sales_today?.count).toBe(sold.length);
    expect(all.tiles.sales_today?.count).toBe(2);
    expect(all.tiles.sales_today?.total).toBe(
      money(sold.reduce((sum, s) => sum + cents(s['total'] as string), 0)),
    );
    expect(all.tiles.sales_today?.total).toBe('12500.00');
    expect(all.tiles.sales_today?.on_contract).toBe('10000.00');
    expect(inMain.tiles.sales_today).toEqual(all.tiles.sales_today);
    expect(inSecond.tiles.sales_today).toMatchObject({ count: 0, total: '0.00' });

    // Collections: the day close preview of the branch.
    const preview = DayClosePreview.parse(
      (await call('get', `/api/day-closes/preview?branch_id=${main}&date=${date}`, owner)).body,
    );
    expect(all.tiles.collections_today).toEqual({
      count: preview.totals.collections.count,
      total: preview.totals.collections.total,
      in_field: preview.totals.collections.in_field,
    });
    expect(all.tiles.collections_today).toMatchObject({ count: 1, total: '1000.00' });
    expect(inSecond.tiles.collections_today).toMatchObject({ count: 0, total: '0.00' });

    // Shifts and cash: the shifts list and the cash accounts list.
    const shifts = await call('get', `/api/shifts?status=open&branch_id=${main}`, owner);
    expect(shifts.status, JSON.stringify(shifts.body)).toBe(200);
    expect(inMain.tiles.open_shifts?.count).toBe((shifts.body as { total: number }).total);
    expect(inMain.tiles.open_shifts).toMatchObject({ count: 1, from_earlier_days: 0 });
    expect(inSecond.tiles.open_shifts).toEqual({
      count: 0,
      oldest_opened_at: null,
      from_earlier_days: 0,
    });
    const accounts = await call('get', `/api/cash-accounts?status=active&branch_id=${main}`, owner);
    expect(accounts.status, JSON.stringify(accounts.body)).toBe(200);
    const safes = items(accounts.body).filter((a) => a['kind'] === 'safe');
    expect(inMain.tiles.cash?.safes).toBe(
      money(safes.reduce((sum, a) => sum + cents(a['balance'] as string), 0)),
    );
    const drawer = items(shifts.body).reduce(
      (sum, s) => sum + cents(s['expected_cash'] as string),
      0,
    );
    expect(inMain.tiles.cash?.drawers).toBe(money(drawer));
    expect(inMain.tiles.cash?.wallets).toBe('0.00');
    expect(all.tiles.cash?.total_in_branches).toBe(
      money(
        cents(all.tiles.cash!.safes) +
          cents(all.tiles.cash!.drawers) +
          cents(all.tiles.cash!.wallets),
      ),
    );

    // Overdue: nothing is late yet; the HTTP list says the same.
    const overdue = await call('get', '/api/overdue', owner);
    expect(overdue.status, JSON.stringify(overdue.body)).toBe(200);
    const totals = (overdue.body as { totals: { contracts: number; overdue_amount: string } })
      .totals;
    expect(all.tiles.overdue).toEqual({
      contracts: totals.contracts,
      amount: totals.overdue_amount,
      customers: 0,
    });

    // Low stock: each branch's own count in the low-stock summary (the chair has 6 of 5 in main, the TV is
    // below the shop minimum; the second branch holds nothing).
    const low = await call('get', '/api/stock/low-summary', owner);
    expect(low.status, JSON.stringify(low.body)).toBe(200);
    expect(all.tiles.low_stock?.products).toBe((low.body as { total: number }).total);
    const perBranch = (low.body as { branches: { branch_id: string; low: number }[] }).branches;
    expect(inMain.tiles.low_stock?.products).toBe(perBranch.find((b) => b.branch_id === main)?.low);
    expect(inSecond.tiles.low_stock?.products).toBe(
      perBranch.find((b) => b.branch_id === second)?.low,
    );
    expect(inSecond.tiles.low_stock?.products).toBeGreaterThan(0);

    // Nothing needs a person yet.
    expect(all.tiles.unclosed_days).toEqual({ days: 0, branches: 0 });
    expect(all.tiles.approvals).toEqual({ discount: 0, purchase: 0, credit: 0, total: 0 });
  }, 120_000);

  it('shows a cashier only the tiles their keys open and refuses a branch of another shop', async () => {
    const view = await dashboard(cashier);
    expect(view.tiles.sales_today).not.toBeNull();
    expect(view.tiles.cash).toBeNull();
    expect(view.tiles.collections_today).toBeNull();
    expect(view.tiles.overdue).toBeNull();
    expect(view.tiles.approvals).toBeNull();
    const denied = await call('get', `/api/dashboard?branch_id=${second}`, cashier);
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('BRANCH_DENIED');
    const unknown = await call(
      'get',
      '/api/dashboard?branch_id=00000000-0000-4000-8000-000000000d01',
      owner,
    );
    expect(unknown.status).toBe(404);
    expect(code(unknown)).toBe('BRANCH_NOT_FOUND');
    const bad = await call('get', '/api/dashboard?branch_id=nope', owner);
    expect(bad.status).toBe(400);
    expect(code(bad)).toBe('VALIDATION_FAILED');
  });

  it('answers in well under a second and a half on this shop', async () => {
    const started = performance.now();
    await dashboard(owner);
    expect(performance.now() - started).toBeLessThan(1500);
  });
});
