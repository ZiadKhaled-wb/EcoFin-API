import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  Quotation,
  QuotationCreated,
  SalesOrder,
  subtractMoney,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const SHOP_B = 'd1000000-0000-0000-0000-000000000002';
const SHOP_B_BR1 = 'd2000000-0000-0000-0000-000000000021';

describe.skipIf(!RUN)('S10 sales orders against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let org: string;
  let branch: string;
  let customer: string;
  let chair: string;
  let phone: string;
  let units: string[];
  let quoteId: string;
  let flowOrder: SalesOrder;
  let ip = 0;
  // O03: the paired POS computer deposits and cash refunds come from.
  let pos = '';
  const call = (
    method: 'get' | 'post' | 'put',
    path: string,
    opts: { token?: string; orgId?: string; body?: object; key?: string; device?: string } = {},
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.80.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + (opts.token ?? owner));
    const orgId = opts.orgId ?? org;
    if (orgId) r.set('x-org-id', orgId);
    const device = opts.device ?? pos;
    if (device) r.set(DEVICE_TOKEN_HEADER, device);
    if (opts.key) r.set('Idempotency-Key', opts.key);
    return opts.body ? r.send(opts.body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `s10-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.80.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function getOrder(id: string) {
    const r = await call('get', '/api/orders/' + id);
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return SalesOrder.parse(r.body);
  }
  /** An open order of one chair line (from stock), made straight through POST /api/orders. */
  async function newOrder(tag: string) {
    const r = await call('post', '/api/orders', {
      key: key(tag),
      body: {
        branch_id: branch,
        customer_id: customer,
        lines: [{ product_id: chair, quantity: 1, unit_price: '250.00' }],
      },
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return SalesOrder.parse(r.body);
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `s10.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.80.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'S10 shop',
        tenant_slug: `s10-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.80.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;

    const c = await call('post', '/api/customers', {
      body: { full_name: 'S10 customer', phones: ['01012345670'] },
    });
    expect(c.status, JSON.stringify(c.body)).toBe(201);
    customer = (c.body as { id: string }).id;
    const p1 = await call('post', '/api/products', {
      body: { name_ar: 'كرسي', sku: 'S10-CH', cash_price: '250.00' },
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    chair = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', {
      body: { name_ar: 'هاتف', sku: 'S10-PH', cash_price: '5000.00', is_serialized: true },
    });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    phone = (p2.body as { id: string }).id;
    const stocked = await call('post', '/api/stock/adjustments', {
      key: key('stock'),
      body: { branch_id: branch, reason: 'found', lines: [{ product_id: chair, quantity: 10 }] },
    });
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const made = await call('post', '/api/units', {
      key: key('units'),
      body: { product_id: phone, branch_id: branch, cost: '3000.00', serials: [`S10-${STAMP}`] },
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    units = (made.body as { units: { id: string }[] }).units.map((u) => u.id);
    const shift = await call('post', '/api/shifts', {
      key: key('shift'),
      body: { branch_id: branch, opening_float: '0.00' },
    });
    expect(shift.status, JSON.stringify(shift.body)).toBe(201);
  }, 60_000);

  it('A1 quote accepted -> order -> deposit -> balances -> cancel with refund -> cancelled', async () => {
    const q = await call('post', '/api/quotations', {
      key: key('quote'),
      body: {
        branch_id: branch,
        customer_id: customer,
        lines: [{ product_id: chair, quantity: 2, unit_price: '250.00' }],
      },
    });
    expect(q.status, JSON.stringify(q.body)).toBe(201);
    quoteId = QuotationCreated.parse(q.body).id;
    expect((await call('post', '/api/quotations/' + quoteId + '/send')).status).toBe(200);
    const accepted = await call('post', '/api/quotations/' + quoteId + '/accept');
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    const quote = Quotation.parse(accepted.body);

    const made = await call('post', '/api/quotations/' + quoteId + '/order', {
      key: key('from-quote'),
      body: {},
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    flowOrder = SalesOrder.parse(made.body);
    expect(flowOrder).toMatchObject({
      status: 'open',
      quotation_id: quoteId,
      total: quote.total,
      customer_id: customer,
    });
    expect(flowOrder.lines).toHaveLength(1);
    expect(flowOrder.lines[0]).toMatchObject({ product_id: chair, quantity: 2, reserved: 2 });

    const dep = await call('post', '/api/orders/' + flowOrder.id + '/deposits', {
      key: key('deposit'),
      body: { payments: [{ method: 'cash', amount: '100.00' }] },
    });
    expect(dep.status, JSON.stringify(dep.body)).toBe(200);
    const deposited = await getOrder(flowOrder.id);
    expect(deposited.balances).toEqual({
      deposits_paid: '100.00',
      financed: '0.00',
      delivered_value: '0.00',
      unpaid: subtractMoney(quote.total, '100.00'),
    });
    expect(deposited.payments.map((p) => [p.direction, p.method, p.amount])).toEqual([
      ['in', 'cash', '100.00'],
    ]);

    const cancelled = await call('post', '/api/orders/' + flowOrder.id + '/cancel', {
      key: key('cancel'),
      body: { reason: 'Customer changed mind', refund: [{ method: 'cash', amount: '100.00' }] },
    });
    expect(cancelled.status, JSON.stringify(cancelled.body)).toBe(200);
    const after = await getOrder(flowOrder.id);
    expect(after.status).toBe('cancelled');
    expect(after.cancelled_reason).toBe('Customer changed mind');
    expect(after.balances.deposits_paid).toBe('0.00');
    expect(after.lines[0]?.reserved).toBe(0);
    expect(after.payments.map((p) => [p.direction, p.amount])).toEqual([
      ['in', '100.00'],
      ['out', '100.00'],
    ]);
  });

  it('A2 the POS sale route refuses a serial reserved for an order (409)', async () => {
    const r = await call('post', '/api/orders', {
      key: key('reserve-serial'),
      body: {
        branch_id: branch,
        customer_id: customer,
        lines: [{ product_id: phone, quantity: 1, unit_price: '5000.00', unit_ids: [units[0]] }],
      },
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const held = SalesOrder.parse(r.body);
    expect(held.lines[0]?.reserved_units.map((u) => u.id)).toEqual([units[0]]);
    const sale = await call('post', '/api/sales', {
      key: key('sale-reserved'),
      body: {
        lines: [{ product_id: phone, quantity: 1, unit_id: units[0] }],
        expected_total: '5000.00',
      },
    });
    expect(sale.status, JSON.stringify(sale.body)).toBe(409);
    expect(code(sale)).toBe('UNIT_NOT_AVAILABLE');
  });

  it('A3 another shop gets 404 on every S10 route and its list excludes the order', async () => {
    const b = await login('owner.two@ecotech.test');
    const order = await newOrder('cross-shop');
    const line = order.lines[0]!.id;
    // Shop two's owner, from no paired computer (shop one's device token is not theirs).
    const foreign = { token: b, orgId: SHOP_B, device: '' };
    const cases: [string, string, object | undefined, boolean][] = [
      ['get', '/api/orders/' + order.id, undefined, false],
      [
        'post',
        '/api/orders',
        {
          branch_id: SHOP_B_BR1,
          customer_id: customer,
          lines: [{ product_id: chair, quantity: 1, unit_price: '250.00' }],
        },
        true,
      ],
      ['post', '/api/quotations/' + quoteId + '/order', {}, true],
      [
        'post',
        '/api/orders/' + order.id + '/deposits',
        { payments: [{ method: 'cash', amount: '10.00' }] },
        true,
      ],
      ['post', '/api/orders/' + order.id + '/lines/' + line + '/reserve', {}, false],
      [
        'post',
        '/api/orders/' + order.id + '/lines/' + line + '/link-po',
        { po_line_id: line },
        false,
      ],
      ['post', '/api/orders/' + order.id + '/cancel', { reason: 'Not mine', refund: [] }, true],
    ];
    for (const [method, path, body, keyed] of cases) {
      const r = await call(method as 'get' | 'post', path, {
        ...foreign,
        ...(body ? { body } : {}),
        ...(keyed ? { key: key('foreign-' + ip) } : {}),
      });
      expect(r.status, path + ' ' + JSON.stringify(r.body)).toBe(404);
    }
    const list = await call('get', '/api/orders', foreign);
    expect(list.status, JSON.stringify(list.body)).toBe(200);
    expect(JSON.stringify(list.body)).not.toContain(order.id);
    expect((await getOrder(order.id)).status).toBe('open');
  });

  it('A4 a replayed cancel with the same Idempotency-Key refunds once', async () => {
    const order = await newOrder('replay');
    const dep = await call('post', '/api/orders/' + order.id + '/deposits', {
      key: key('replay-deposit'),
      body: { payments: [{ method: 'cash', amount: '50.00' }] },
    });
    expect(dep.status, JSON.stringify(dep.body)).toBe(200);
    const body = { reason: 'Customer changed mind', refund: [{ method: 'cash', amount: '50.00' }] };
    const first = await call('post', '/api/orders/' + order.id + '/cancel', {
      key: key('replay-cancel'),
      body,
    });
    expect(first.status, JSON.stringify(first.body)).toBe(200);
    const again = await call('post', '/api/orders/' + order.id + '/cancel', {
      key: key('replay-cancel'),
      body,
    });
    expect(again.status, JSON.stringify(again.body)).toBe(200);
    expect(again.body).toEqual(first.body);
    const after = await getOrder(order.id);
    expect(after.status).toBe('cancelled');
    expect(after.payments.filter((p) => p.direction === 'out')).toHaveLength(1);
    expect(after.balances.deposits_paid).toBe('0.00');
  });

  it('create, deposit and cancel without an Idempotency-Key are refused before any write', async () => {
    const order = await newOrder('no-key');
    const create = await call('post', '/api/orders', {
      body: {
        branch_id: branch,
        customer_id: customer,
        lines: [{ product_id: chair, quantity: 1, unit_price: '250.00' }],
      },
    });
    const deposit = await call('post', '/api/orders/' + order.id + '/deposits', {
      body: { payments: [{ method: 'cash', amount: '10.00' }] },
    });
    const cancel = await call('post', '/api/orders/' + order.id + '/cancel', {
      body: { reason: 'Customer changed mind', refund: [] },
    });
    for (const r of [create, deposit, cancel]) {
      expect(r.status, JSON.stringify(r.body)).toBe(400);
      expect(code(r)).toBe('VALIDATION_FAILED');
    }
    const after = await getOrder(order.id);
    expect(after.status).toBe('open');
    expect(after.payments).toEqual([]);
  });
});
