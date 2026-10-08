// I01 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh
// shop's product gets ledger movements; GET /api/stock shows on hand / available / low that equal
// the ledger, filters by branch and low stock, and the drill-down lists the movements with the
// running balance. A collector (no stock.view) is refused.
// I02: an adjustment through the API (idempotent), a count (scan, save, post) after which the
// stock equals the counted numbers, and the ledger rows carry the adjustment's number and reason.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  Product,
  StockAdjustment,
  StockCount,
  StockCountDetail,
  StockCountLine,
  StockList,
  StockMovementList,
  StockTransfer,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('I01 stock view against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let collector: string;
  let org: string;
  let main: string;
  let ip = 0;
  const call = (path: string, token = owner) => {
    const r = request(app)
      .get(path)
      .set('X-Forwarded-For', `198.18.14.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    return r;
  };
  const post = (path: string, body: object) =>
    request(app)
      .post(path)
      .set('X-Forwarded-For', `198.18.14.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + owner)
      .set('x-org-id', org)
      .send(body);
  const send = (method: 'post' | 'put', path: string, body: object, key?: string) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.14.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + owner)
      .set('x-org-id', org);
    if (key) r.set('Idempotency-Key', key);
    return r.send(body);
  };
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.14.${(++ip % 250) + 1}`)
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
    const email = `i01.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.14.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'I01 shop',
        tenant_slug: `i01-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.14.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const branch = await service.from('branches').select('id').eq('organization_id', org).single();
    main = branch.data!.id as string;

    const collectorEmail = `i01.collector.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: collectorEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service.from('employees').insert({
      organization_id: org,
      auth_user_id: user.data.user!.id,
      email: collectorEmail,
      full_name: 'Collector',
      role: 'COLLECTOR',
    });
    expect(emp.error).toBeNull();
    collector = await login(collectorEmail);
  });

  it('shows ledger-true numbers, filters, and the movement drill-down', async () => {
    const created = await post('/api/products', {
      name_ar: 'تلفزيون I01',
      sku: `I01-TV-${STAMP}`,
      cash_price: '100.00',
      min_stock: 5,
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const product = Product.parse(created.body);
    // Ledger movements (purchases and sales are later slices).
    for (const [quantity, type] of [
      [8, 'purchase_in'],
      [-4, 'sale_out'],
    ] as const) {
      const moved = await service.from('stock_movements').insert({
        organization_id: org,
        product_id: product.id,
        branch_id: main,
        quantity,
        type,
        source_type: 'stock_adjustment',
        source_id: crypto.randomUUID(),
      });
      expect(moved.error).toBeNull();
    }

    const res = await call(`/api/stock?branch_id=${main}&search=I01-TV-${STAMP}`);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    const list = StockList.parse(res.body);
    expect(list.total).toBe(1);
    expect(list.items[0]).toMatchObject({
      product_id: product.id,
      branch_id: main,
      on_hand: 4,
      reserved: 0,
      available: 4,
      min_level: 5,
      low: true,
    });
    // Done when: equals the ledger sum.
    const ledger = await service
      .from('stock_movements')
      .select('quantity')
      .eq('organization_id', org)
      .eq('product_id', product.id);
    expect(ledger.data!.reduce((s, m) => s + (m.quantity as number), 0)).toBe(
      list.items[0]!.on_hand,
    );

    const low = StockList.parse((await call('/api/stock?low_only=true')).body);
    expect(low.items.some((r) => r.product_id === product.id)).toBe(true);

    const moves = await call(`/api/stock/movements?product_id=${product.id}&branch_id=${main}`);
    expect(moves.status, JSON.stringify(moves.body)).toBe(200);
    const history = StockMovementList.parse(moves.body);
    expect(history.items.map((m) => [m.type, m.quantity, m.balance_after])).toEqual([
      ['sale_out', -4, 4],
      ['purchase_in', 8, 8],
    ]);

    expect((await call('/api/stock?low_only=maybe')).status).toBe(400);
    expect((await call('/api/stock/movements')).status).toBe(400);
  });

  it('I02: adjusts, counts and posts so the stock equals the counted numbers', async () => {
    const created = await post('/api/products', {
      name_ar: 'كابل I02',
      sku: `I02-CB-${STAMP}`,
      cash_price: '5.00',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const product = Product.parse(created.body);
    const body = {
      branch_id: main,
      reason: 'found',
      lines: [{ product_id: product.id, quantity: 7 }],
    };

    expect((await send('post', '/api/stock/adjustments', body)).status).toBe(400); // no key
    const adj = await send('post', '/api/stock/adjustments', body, `i02-adj-${STAMP}`);
    expect(adj.status, JSON.stringify(adj.body)).toBe(201);
    const adjustment = StockAdjustment.parse(adj.body);
    const again = await send('post', '/api/stock/adjustments', body, `i02-adj-${STAMP}`);
    expect(StockAdjustment.parse(again.body).id).toBe(adjustment.id);
    const wrongWay = await send(
      'post',
      '/api/stock/adjustments',
      { ...body, reason: 'damage' },
      `i02-adj-bad-${STAMP}`,
    );
    expect(wrongWay.status).toBe(400);
    const tooMuch = await send(
      'post',
      '/api/stock/adjustments',
      { ...body, reason: 'loss', lines: [{ product_id: product.id, quantity: -8 }] },
      `i02-adj-oos-${STAMP}`,
    );
    expect(tooMuch.status).toBe(409);
    expect(ErrorResponse.parse(tooMuch.body).error.code).toBe('OUT_OF_STOCK');

    const opened = await send(
      'post',
      '/api/stock/counts',
      { branch_id: main },
      `i02-count-${STAMP}`,
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    const count = StockCount.parse(opened.body);
    const scanned = await send('post', `/api/stock/counts/${count.id}/scan`, {
      code: product.barcode,
    });
    expect(StockCountLine.parse(scanned.body)).toMatchObject({ counted_qty: 1, expected_qty: 7 });
    const saved = await send('put', `/api/stock/counts/${count.id}/lines`, {
      lines: [{ product_id: product.id, counted_qty: 5 }],
    });
    expect(StockCount.parse(saved.body)).toMatchObject({ lines_counted: 1, quantity_out: 2 });
    const different = StockCountDetail.parse(
      (await call(`/api/stock/counts/${count.id}?filter=different`)).body,
    );
    expect(different.lines.items.map((l) => [l.product_id, l.difference])).toEqual([
      [product.id, -2],
    ]);
    const posted = await send(
      'post',
      `/api/stock/counts/${count.id}/post`,
      { uncounted_as_zero: true },
      `i02-post-${STAMP}`,
    );
    expect(posted.status, JSON.stringify(posted.body)).toBe(200);
    expect(StockCount.parse(posted.body)).toMatchObject({ status: 'posted' });

    // Done when: the stock equals the counted number and the ledger rows carry the reason.
    const stock = StockList.parse(
      (await call(`/api/stock?branch_id=${main}&search=I02-CB-${STAMP}`)).body,
    );
    expect(stock.items[0]?.on_hand).toBe(5);
    const moves = StockMovementList.parse(
      (await call(`/api/stock/movements?product_id=${product.id}`)).body,
    );
    expect(moves.items.map((m) => [m.quantity, m.reason, m.source_number])).toEqual([
      [-2, 'count', StockCount.parse(posted.body).adjustment_number],
      [7, 'found', adjustment.number],
    ]);
  });

  it('I03: a transfer is never counted in both branches or in neither', async () => {
    const created = await post('/api/products', {
      name_ar: 'شاشة I03',
      sku: `I03-SC-${STAMP}`,
      cash_price: '50.00',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const product = Product.parse(created.body);
    const found = await send(
      'post',
      '/api/stock/adjustments',
      { branch_id: main, reason: 'found', lines: [{ product_id: product.id, quantity: 6 }] },
      `i03-found-${STAMP}`,
    );
    expect(found.status, JSON.stringify(found.body)).toBe(201);
    const branch = await post('/api/branches', { name: 'I03 second', code: 'I3B' });
    expect(branch.status, JSON.stringify(branch.body)).toBe(201);
    const second = branch.body.id as string;

    const body = {
      from_branch_id: main,
      to_branch_id: second,
      lines: [{ product_id: product.id, quantity: 6 }],
    };
    const draft = await send('post', '/api/stock/transfers', body, `i03-tr-${STAMP}`);
    expect(draft.status, JSON.stringify(draft.body)).toBe(201);
    const transfer = StockTransfer.parse(draft.body);
    expect(transfer.status).toBe('draft');
    const sent = await send('post', `/api/stock/transfers/${transfer.id}/send`, {});
    expect(StockTransfer.parse(sent.body).status).toBe('sent');

    const rows = async () =>
      StockList.parse((await call(`/api/stock?search=I03-SC-${STAMP}`)).body).items;
    const at = (items: Awaited<ReturnType<typeof rows>>, b: string) =>
      items.find((r) => r.branch_id === b)!;
    let items = await rows();
    // In transit: gone from main, not yet on hand in second, shown as in transit there.
    expect([
      at(items, main).on_hand,
      at(items, second).on_hand,
      at(items, second).in_transit,
    ]).toEqual([0, 0, 6]);

    const lineId = StockTransfer.parse(sent.body).lines[0]!.id;
    const received = await send('post', `/api/stock/transfers/${transfer.id}/receive`, {
      lines: [{ line_id: lineId, qty_received: 5, reason: 'loss' }],
    });
    expect(received.status, JSON.stringify(received.body)).toBe(200);
    const done = StockTransfer.parse(received.body);
    expect(done.status).toBe('partially_received');
    expect(done.adjustments.map((a) => a.reason)).toEqual(['loss']);
    items = await rows();
    expect([
      at(items, main).on_hand,
      at(items, second).on_hand,
      at(items, second).in_transit,
    ]).toEqual([0, 5, 0]);
    const cancel = await send('post', `/api/stock/transfers/${transfer.id}/cancel`, {});
    expect(cancel.status).toBe(409);
    expect(ErrorResponse.parse(cancel.body).error.code).toBe('TRANSFER_ALREADY_SENT');
  });

  it('refuses a role without stock.view', async () => {
    for (const path of [
      '/api/stock',
      `/api/stock/movements?product_id=${main}`,
      '/api/stock/adjustments',
      '/api/stock/counts',
      '/api/stock/transfers',
    ]) {
      const res = await call(path, collector);
      expect(res.status).toBe(403);
      expect(ErrorResponse.parse(res.body).error.code).toBe('PERMISSION_DENIED');
    }
  });
});
