// D02 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop sells,
// voids a sale, sells on installments and takes a chair back through the API; the sales report for the
// day equals what the sales history shows (count, total), the returns equal the return documents, its
// self-check passes, the voided sale is nowhere, a cashier with report.view sees no cost and one without
// it is refused. (Every grouping, filter and edge: supabase/tests/d02_sales_report_test.sql.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuthLoginResponse, ErrorResponse, SalesReport } from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

// Test-only decimal helper: whole cents, so the comparison is exact.
const cents = (money: string) => Math.round(Number(money) * 100);

describe.skipIf(!RUN)('D02 sales report against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let viewer: string;
  let clerk: string;
  let org: string;
  let main: string;
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
      .set('X-Forwarded-For', `198.18.88.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `d02-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.88.${(++ip % 250) + 1}`)
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
  async function employee(label: string, role: string) {
    const email = `d02.${label}.${STAMP}@ecotech.test`;
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
        full_name: `D02 ${label}`,
        role,
        default_branch_id: main,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: main });
    return { token: await login(email), id: emp.data!.id as string };
  }
  const report = async (token: string, query: string) => {
    const res = await call('get', '/api/reports/sales?' + query, token);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return SalesReport.parse(res.body);
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
    const email = `d02.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.88.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'D02 shop',
        tenant_slug: `d02-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.88.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const branch = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(branch.error).toBeNull();
    main = branch.data!.id as string;
    pos = (await pairTestDevice(service, org, main)).token;

    // A cashier allowed to read reports (report.view) but not the costs, and one with no report key.
    const v = await employee('viewer', 'CASHIER');
    viewer = v.token;
    const grant = await service.from('employee_permission_overrides').insert({
      organization_id: org,
      employee_id: v.id,
      permission_key: 'report.view',
      granted: true,
    });
    expect(grant.error).toBeNull();
    clerk = (await employee('clerk', 'CASHIER')).token;

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
      sku: `D02-CH-${STAMP}`,
      cash_price: '250.00',
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    chair = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: `D02-TV-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    tv = (p2.body as { id: string }).id;
    // The cost snapshot the sale lines copy (purchases set it in real life).
    for (const [id, cost] of [
      [chair, 100],
      [tv, 9000],
    ] as const) {
      const set = await service.from('products').update({ avg_cost: cost }).eq('id', id);
      expect(set.error).toBeNull();
    }
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
      full_name: `D02 customer ${STAMP}`,
      phones: ['01500000088'],
      national_id: '29001010100788',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    customerId = (created.body as { id: string }).id;
    const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '100000.00',
      reason: 'D02 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
  }, 120_000);

  it('equals the sales pages after a shop sells, voids, sells on installments and takes a chair back', async () => {
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
    const sale1 = await sell('sale-1', chair, 2, '500.00');
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
    const able = await call('get', `/api/sales/${sale1}/returnable`, owner);
    expect(able.status, JSON.stringify(able.body)).toBe(200);
    const line = (able.body as { lines: { sale_line_id: string }[] }).lines[0]!.sale_line_id;
    const back = await call(
      'post',
      '/api/returns',
      owner,
      {
        sale_id: sale1,
        lines: [{ sale_line_id: line, quantity: 1 }],
        refunds: [{ method: 'cash', amount: '250.00' }],
        reason: 'Customer changed his mind',
        expected_total: '250.00',
      },
      key('return'),
    );
    expect(back.status, JSON.stringify(back.body)).toBe(201);

    const day = await report(owner, `from=${date}&to=${date}&group_by=day`);
    const history = await call('get', `/api/sales?from=${date}&to=${date}&page_size=100`, owner);
    expect(history.status, JSON.stringify(history.body)).toBe(200);
    const all = items(history.body);
    const sold = all.filter((s) => s['status'] !== 'voided');
    expect(all.some((s) => s['status'] === 'voided')).toBe(true);

    // The sale pages: the count and the gross total of the sales that count (no voided sale).
    expect(day.totals.sales_count).toBe(sold.length);
    expect(day.totals.sales_count).toBe(2);
    expect(day.totals.gross).toBe(
      (sold.reduce((sum, s) => sum + cents(s['total'] as string), 0) / 100).toFixed(2),
    );
    expect(day.totals.gross).toBe('12500.00');
    expect(day.totals.quantity).toBe(3);
    // The return document: one chair, 250.
    expect(day.totals).toMatchObject({
      return_count: 1,
      returned_quantity: 1,
      returned_gross: '250.00',
      net_quantity: 2,
      cost: '9200.00',
      returned_cost: '100.00',
      net_cost: '9100.00',
      contract_profit: '2000.00',
    });
    // Revenue is the gross without VAT; margin is revenue - cost; the contract profit is not in it.
    expect(cents(day.totals.revenue!) + cents(day.totals.tax!)).toBe(cents(day.totals.gross!));
    expect(cents(day.totals.margin!)).toBe(cents(day.totals.revenue!) - 920000);
    expect(day.rows).toHaveLength(1);
    expect(day.rows[0]).toMatchObject({ key: date, sales_count: 2, return_count: 1 });
    expect(day.check).toMatchObject({ rows_match: true });
    expect(day.can_see_cost).toBe(true);

    // The same totals whatever the grouping; products and sale types split them.
    const byProduct = await report(owner, `from=${date}&to=${date}&group_by=product`);
    expect(byProduct.totals).toEqual(day.totals);
    expect(byProduct.check).toMatchObject({ rows_match: true });
    expect(byProduct.rows.map((r) => r.key).sort()).toEqual([chair, tv].sort());
    expect(byProduct.rows.find((r) => r.key === chair)).toMatchObject({
      quantity: 2,
      returned_quantity: 1,
      net_quantity: 1,
    });
    const byType = await report(owner, `from=${date}&to=${date}&group_by=sale_type`);
    expect(byType.rows.find((r) => r.key === 'installment')).toMatchObject({
      sales_count: 1,
      gross: '12000.00',
      contract_profit: '2000.00',
    });
    expect(byType.rows.find((r) => r.key === 'cash')).toMatchObject({
      sales_count: 1,
      gross: '500.00',
      returned_gross: '250.00',
    });
    const byPayment = await report(owner, `from=${date}&to=${date}&group_by=payment_type`);
    expect(byPayment.check).toMatchObject({ rows_match: true });
    const moneyIn = byPayment.rows.reduce((sum, r) => sum + cents(r.amount!), 0);
    expect(moneyIn).toBe(1250000);
    expect(byPayment.rows.find((r) => r.key === 'on_contract')?.amount).toBe('10000.00');

    // A filter makes the headers incomparable: totals are the rows' and the check is null.
    const filtered = await report(
      owner,
      `from=${date}&to=${date}&group_by=day&product_id=${chair}`,
    );
    expect(filtered.check).toBeNull();
    expect(filtered.totals).toMatchObject({ sales_count: 1, quantity: 2, gross: '500.00' });

    // Paging: one row per page, the totals always cover the whole result.
    const page = await report(owner, `from=${date}&to=${date}&group_by=product&page_size=1&page=2`);
    expect(page.rows).toHaveLength(1);
    expect(page.total_count).toBe(2);
    expect(page.totals).toEqual(day.totals);
    expect(page.page).toBe(2);

    // A cashier with report.view reads the report without any cost.
    const seen = await report(viewer, `from=${date}&to=${date}&group_by=product`);
    expect(seen.can_see_cost).toBe(false);
    expect(seen.totals).toMatchObject({
      revenue: day.totals.revenue,
      cost: null,
      margin: null,
      contract_profit: null,
      returned_gross: '250.00',
    });
    expect(seen.rows.every((r) => r.cost === null && r.margin === null)).toBe(true);
    const refused = await call(
      'get',
      `/api/reports/sales?from=${date}&to=${date}&group_by=product&sort=margin_desc`,
      viewer,
    );
    expect(refused.status).toBe(400);
    expect(code(refused)).toBe('VALIDATION_FAILED');
  }, 120_000);

  it('refuses a cashier without report.view, bad queries, an org id and another shop', async () => {
    const date = await today();
    const q = `from=${date}&to=${date}&group_by=day`;
    const denied = await call('get', '/api/reports/sales?' + q, clerk);
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    const noToken = await request(app)
      .get('/api/reports/sales?' + q)
      .set('X-Forwarded-For', `198.18.88.${(++ip % 250) + 1}`);
    expect(noToken.status).toBe(401);

    const long = await call(
      'get',
      '/api/reports/sales?from=2025-10-30&to=2026-10-31&group_by=day',
      owner,
    );
    expect(long.status).toBe(400);
    expect(code(long)).toBe('VALIDATION_FAILED');
    const inverted = await call(
      'get',
      '/api/reports/sales?from=2026-10-31&to=2026-10-01&group_by=day',
      owner,
    );
    expect(inverted.status).toBe(400);
    const grouping = await call(
      'get',
      `/api/reports/sales?from=${date}&to=${date}&group_by=colour`,
      owner,
    );
    expect(grouping.status).toBe(400);
    const injected = await call('get', `/api/reports/sales?${q}&organization_id=${org}`, owner);
    expect(injected.status).toBe(400);
    const moneyByProduct = await call(
      'get',
      `/api/reports/sales?from=${date}&to=${date}&group_by=payment_type&product_id=${chair}`,
      owner,
    );
    expect(moneyByProduct.status).toBe(400);

    const unknownBranch = await call(
      'get',
      `/api/reports/sales?${q}&branch_id=00000000-0000-4000-8000-0000000002d2`,
      owner,
    );
    expect(unknownBranch.status).toBe(404);
    expect(code(unknownBranch)).toBe('BRANCH_NOT_FOUND');
    const unknownProduct = await call(
      'get',
      `/api/reports/sales?${q}&product_id=00000000-0000-4000-8000-0000000002d3`,
      owner,
    );
    expect(unknownProduct.status).toBe(404);
    expect(code(unknownProduct)).toBe('PRODUCT_NOT_FOUND');
  }, 120_000);
});
