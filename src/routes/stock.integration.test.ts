// I01 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh
// shop's product gets ledger movements; GET /api/stock shows on hand / available / low that equal
// the ledger, filters by branch and low stock, and the drill-down lists the movements with the
// running balance. A collector (no stock.view) is refused.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  Product,
  StockList,
  StockMovementList,
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

  it('refuses a role without stock.view', async () => {
    for (const path of ['/api/stock', `/api/stock/movements?product_id=${main}`]) {
      const res = await call(path, collector);
      expect(res.status).toBe(403);
      expect(ErrorResponse.parse(res.body).error.code).toBe('PERMISSION_DENIED');
    }
  });
});
