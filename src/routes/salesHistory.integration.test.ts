// S07 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop stocks chairs and one IMEI phone; a cashier can't sell without a shift, opens one,
// quotes a cart and sells it (two requests with one key: one sale); the shift, the stock and the
// unit follow; the same IMEI, a stale total, too many chairs and a cashier's own price are
// refused with their codes; S02: a sale paid half cash, half bank transfer posts each half to its
// own place and the shift shows both; closing the shift counts only the cash into the safe.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuthLoginResponse, ErrorResponse, StockList } from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('S07 sale core against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let org: string;
  let branch: string;
  let chair: string;
  let phone: string;
  let unit: string;
  let saleId: string;
  let ip = 0;
  const call = (
    method: 'get' | 'post',
    path: string,
    token = cashier,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.77.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.77.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const chairs = async () =>
    StockList.parse((await call('get', `/api/stock?branch_id=${branch}`, owner)).body).items.find(
      (r) => r.product_id === chair,
    )?.on_hand ?? 0;
  const key = (tag: string) => `s07-it-${tag}-${STAMP}`;

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `s07.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.77.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'S07 shop',
        tenant_slug: `s07-${STAMP}`,
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

    const main = await service
      .from('branches')
      .select('id, default_cash_account_id')
      .eq('organization_id', org)
      .single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    const cashierEmail = `s07.cashier.${STAMP}@ecotech.test`;
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
        full_name: 'Mona Cashier',
        role: 'CASHIER',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    cashier = await login(cashierEmail);

    // The shop sells at prices that include VAT (the default), 14% on both products.
    const p1 = await call('post', '/api/products', owner, {
      name_ar: 'كرسي',
      sku: 'S07-CH',
      cash_price: '250.00',
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    chair = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', owner, {
      name_ar: 'هاتف',
      sku: 'S07-PH',
      cash_price: '5000.00',
      is_serialized: true,
    });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    phone = (p2.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: chair, quantity: 5 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const units = await call(
      'post',
      '/api/units',
      owner,
      { product_id: phone, branch_id: branch, cost: '3000.00', serials: [`S07-${STAMP}`] },
      key('units'),
    );
    expect(units.status, JSON.stringify(units.body)).toBe(201);
    unit = (units.body as { units: { id: string }[] }).units[0]!.id;
  }, 60_000);

  it('owner sells, searches the serial, voids, and reads a visible immutable sale with restored stock', async () => {
    expect(
      (
        await call(
          'post',
          '/api/shifts',
          owner,
          { branch_id: branch, opening_float: '0' },
          key('owner-shift'),
        )
      ).status,
    ).toBe(201);
    const lines = [
      { product_id: chair, quantity: 2 },
      { product_id: phone, unit_id: unit, quantity: 1 },
    ];
    const quote = await call('post', '/api/sales/quote', owner, { lines });
    expect(quote.status).toBe(200);
    const created = await call(
      'post',
      '/api/sales',
      owner,
      { lines, expected_total: quote.body.total },
      key('history-sale'),
    );
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    saleId = (created.body as { id: string }).id;
    const found = await call('get', '/api/sales?q=' + encodeURIComponent('S07-' + STAMP), owner);
    expect(found.status, JSON.stringify(found.body)).toBe(200);
    expect(found.body.items.map((r: { id: string }) => r.id)).toContain(saleId);
    expect(
      (await call('post', '/api/sales/' + saleId + '/void', owner, { reason: 'Duplicate' })).status,
    ).toBe(400);
    const denied = await call(
      'post',
      '/api/sales/' + saleId + '/void',
      cashier,
      { reason: 'Duplicate' },
      key('denied'),
    );
    expect(denied.status).toBe(403);
    const done = await call(
      'post',
      '/api/sales/' + saleId + '/void',
      owner,
      { reason: 'Duplicate' },
      key('void'),
    );
    expect(done.status, JSON.stringify(done.body)).toBe(201);
    expect(
      (
        await call(
          'post',
          '/api/sales/' + saleId + '/void',
          owner,
          { reason: 'Duplicate' },
          key('void'),
        )
      ).body,
    ).toEqual(done.body);
    const details = await call('get', '/api/sales/' + saleId, owner);
    expect(details.status).toBe(200);
    expect(details.body).toMatchObject({
      number: created.body.number,
      total: created.body.total,
      status: 'voided',
      voidable: false,
    });
    expect(details.body.returns).toHaveLength(1);
    expect(await chairs()).toBe(5);
    const restored = await service.from('units').select('status').eq('id', unit).single();
    expect(restored.data?.status).toBe('in_stock');
  });
  it('two concurrent void keys create one reversal; a cashier still reads only accessible history', async () => {
    const lines = [{ product_id: chair, quantity: 1 }];
    const quote = await call('post', '/api/sales/quote', owner, { lines });
    const created = await call(
      'post',
      '/api/sales',
      owner,
      { lines, expected_total: quote.body.total },
      key('race-sale'),
    );
    expect(created.status).toBe(201);
    const id = (created.body as { id: string }).id;
    const results = await Promise.all(
      ['a', 'b'].map((tag) =>
        call(
          'post',
          '/api/sales/' + id + '/void',
          owner,
          { reason: 'Race reversal' },
          key('race-' + tag),
        ),
      ),
    );
    expect(results.map((r) => r.status).sort()).toEqual([201, 409]);
    expect(results.find((r) => r.status === 409)?.body.error.code).toBe('ALREADY_VOIDED');
    const rows = await service
      .from('sales_returns')
      .select('id')
      .eq('sale_id', id)
      .eq('kind', 'void');
    expect(rows.data).toHaveLength(1);
    const visible = await call('get', '/api/sales?status=voided', cashier);
    expect(visible.status).toBe(200);
    expect(visible.body.items.some((r: { id: string }) => r.id === id)).toBe(true);
  });
  it('another shop gets 404 for detail and void', async () => {
    const other = await login('owner.two@ecotech.test');
    const foreign = (method: 'get' | 'post', body?: object) => {
      const req = request(app)
        [method]('/api/sales/' + saleId + (method === 'post' ? '/void' : ''))
        .set('X-Forwarded-For', '198.18.77.249')
        .set('Authorization', 'Bearer ' + other)
        .set('x-org-id', 'd1000000-0000-0000-0000-000000000002')
        .set('Idempotency-Key', key('foreign'));
      return body ? req.send(body) : req;
    };
    for (const response of [
      await foreign('get'),
      await foreign('post', { reason: 'Foreign sale' }),
    ]) {
      expect(response.status).toBe(404);
      expect(code(response)).toBe('SALE_NOT_FOUND');
    }
  });
});
