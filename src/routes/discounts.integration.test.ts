// S03 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// with caps CASHIER 5 / BRANCH_MANAGER 15. Done when: a cashier can't go above the cap through the
// API (403 DISCOUNT_ABOVE_CAP and nothing is written) and the tax of a discounted sale is right.
// The approval runs end to end (the cashier asks, the manager lists and approves, the cashier
// reads it and sells, a second sale with it is refused), and another shop can't touch it.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  DiscountApproval,
  DiscountApprovalList,
  DiscountApprovalRequested,
  ErrorResponse,
  Sale,
  SaleQuote,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('S03 discounts against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let manager: string;
  let otherOwner: string;
  let org: string;
  let otherOrg: string;
  let branch: string;
  let tv: string;
  let ip = 0;
  // O03: two paired POS computers of the shop, as the owner and the cashier each keep a shift
  // open: the owner's requests come from the second one, everyone else's from the first.
  let pos = '';
  let ownerPos = '';
  const call = (
    method: 'get' | 'post' | 'patch',
    path: string,
    token: string,
    body?: object,
    key?: string,
    shop = org,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.65.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (shop) r.set('x-org-id', shop);
    const device = token === owner ? ownerPos : pos;
    if (device && shop === org) r.set(DEVICE_TOKEN_HEADER, device);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `s03-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.65.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function provision(tag: string) {
    const admin = await login('superadmin@ecotech.test');
    const email = `s03.${tag}.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.65.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: `S03 shop ${tag}`,
        tenant_slug: `s03-${tag}-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.65.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    return { org: shop.body.organization_id as string, token: await login(email) };
  }
  async function employee(role: 'CASHIER' | 'BRANCH_MANAGER', tag: string) {
    const email = `s03.${tag}.${STAMP}@ecotech.test`;
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
        full_name: `S03 ${tag}`,
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
  const count = async (table: string, type?: string) => {
    let q = service
      .from(table)
      .select('id', { count: 'exact', head: true })
      .eq('organization_id', org);
    if (type) q = q.eq('type', type);
    const res = await q;
    return res.count ?? 0;
  };
  const written = async () => ({
    sales: await count('sales'),
    stock: await count('stock_movements', 'sale_out'),
    cash: await count('cash_movements', 'sale'),
  });
  const onHand = async () => {
    const r = await service
      .from('stock_levels')
      .select('on_hand')
      .eq('organization_id', org)
      .eq('product_id', tv)
      .eq('branch_id', branch)
      .eq('stock_state', 'sellable')
      .single();
    return r.data?.on_hand as number;
  };
  const sell = (token: string, body: object, tag: string, shop = org) =>
    call('post', '/api/sales', token, body, key(tag), shop);

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const shop = await provision('a');
    org = shop.org;
    owner = shop.token;
    const other = await provision('b');
    otherOrg = other.org;
    otherOwner = other.token;
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;
    ownerPos = (await pairTestDevice(service, org, branch, 'Test POS 2')).token;
    cashier = await employee('CASHIER', 'cashier');
    manager = await employee('BRANCH_MANAGER', 'manager');

    const caps = await call('patch', '/api/settings', owner, {
      discount_caps: { CASHIER: 5, BRANCH_MANAGER: 15 },
    });
    expect(caps.status, JSON.stringify(caps.body)).toBe(200);
    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: 'S03-TV',
      cash_price: '1140.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: tv, quantity: 20 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    for (const [token, tag] of [
      [owner, 'owner'],
      [cashier, 'cashier'],
    ] as const) {
      const opened = await call(
        'post',
        '/api/shifts',
        token,
        { branch_id: branch, opening_float: '0' },
        key(`shift-${tag}`),
      );
      expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    }
  }, 120_000);

  it('Done when: a cashier at 6 % is refused with 403 DISCOUNT_ABOVE_CAP and nothing is written', async () => {
    const before = await written();
    const stock = await onHand();
    const lines = [{ product_id: tv, quantity: 1, discount: { type: 'percent', value: '6' } }];
    const res = await sell(
      cashier,
      { lines, expected_total: '1071.60', discount_reason: 'Regular customer' },
      'cap-6',
    );
    expect(res.status, JSON.stringify(res.body)).toBe(403);
    expect(code(res)).toBe('DISCOUNT_ABOVE_CAP');
    expect(ErrorResponse.parse(res.body).error.details).toEqual({
      line_no: 1,
      cap_pct: '5.00',
      effective_pct: '6.00',
    });
    expect(await written()).toEqual(before);
    expect(await onHand()).toBe(stock);
    // The same cashier at exactly 5 % sells.
    const ok = await sell(
      cashier,
      {
        lines: [{ product_id: tv, quantity: 1, discount: { type: 'percent', value: '5' } }],
        expected_total: '1083.00',
        discount_reason: 'Regular customer',
      },
      'cap-5',
    );
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    expect(Sale.parse(ok.body)).toMatchObject({ discount_total: '57.00', total: '1083.00' });
    // The client can't send a fingerprint of its own.
    const fingerprint = await sell(
      cashier,
      { lines, expected_total: '1071.60', discount_reason: 'Regular customer', fingerprint: 'x' },
      'fingerprint',
    );
    expect(fingerprint.status).toBe(400);
  });

  it('Done when: the tax of a discounted sale (prices include VAT) is stored correctly', async () => {
    const lines = [{ product_id: tv, quantity: 1, discount: { type: 'percent', value: '10' } }];
    const quoted = await call('post', '/api/sales/quote', owner, { lines });
    expect(quoted.status, JSON.stringify(quoted.body)).toBe(200);
    expect(SaleQuote.parse(quoted.body)).toMatchObject({
      discount_total: '114.00',
      tax_total: '126.00',
      total: '1026.00',
    });
    const sold = await sell(
      owner,
      { lines, expected_total: '1026.00', discount_reason: 'Loyal customer' },
      'tax',
    );
    expect(sold.status, JSON.stringify(sold.body)).toBe(201);
    const sale = Sale.parse(sold.body);
    expect(sale).toMatchObject({
      subtotal: '1140.00',
      discount_total: '114.00',
      discount_reason: 'Loyal customer',
      tax_total: '126.00',
      total: '1026.00',
    });
    const row = await service
      .from('sales')
      .select('subtotal, discount_total, tax_total, total, discount_reason')
      .eq('id', sale.id)
      .single();
    expect(row.data).toMatchObject({
      subtotal: 1140,
      discount_total: 114,
      tax_total: 126,
      total: 1026,
      discount_reason: 'Loyal customer',
    });
    // The whole-sale discount is refused without a reason.
    const noReason = await sell(
      owner,
      {
        lines: [{ product_id: tv, quantity: 1 }],
        expected_total: '1026.00',
        sale_discount: { type: 'percent', value: '10' },
      },
      'no-reason',
    );
    expect(noReason.status).toBe(400);
    expect(code(noReason)).toBe('DISCOUNT_REASON_REQUIRED');
  });

  it('the approval runs end to end: ask, list, approve, read, sell once', async () => {
    const lines = [{ product_id: tv, quantity: 1, discount: { type: 'percent', value: '8' } }];
    const asked = await call('post', '/api/sales/discount-approvals', cashier, {
      branch_id: branch,
      lines,
      reason: 'Regular customer, 8 % agreed',
    });
    expect(asked.status, JSON.stringify(asked.body)).toBe(201);
    const requested = DiscountApprovalRequested.parse(asked.body);
    expect(requested).toMatchObject({ max_effective_pct: '8.00', cap_pct: '5.00' });

    // Pending: it can't be used yet.
    const body = {
      lines,
      expected_total: '1048.80',
      discount_reason: 'Regular customer, 8 % agreed',
      discount_approval_id: requested.approval_id,
    };
    const early = await sell(cashier, body, 'ap-early');
    expect(early.status).toBe(409);
    expect(code(early)).toBe('APPROVAL_INVALID');
    // A cashier can neither list nor decide.
    expect(
      (await call('get', '/api/approvals?kind=discount_above_cap&status=pending', cashier)).status,
    ).toBe(403);
    const cashierDecides = await call(
      'post',
      `/api/approvals/${requested.approval_id}/decide`,
      cashier,
      {
        approve: true,
      },
    );
    expect(cashierDecides.status).toBe(403);

    // The manager sees it and approves it from their own session.
    const listed = await call(
      'get',
      '/api/approvals?kind=discount_above_cap&status=pending',
      manager,
    );
    expect(listed.status, JSON.stringify(listed.body)).toBe(200);
    const item = DiscountApprovalList.parse(listed.body).items.find(
      (a) => a.id === requested.approval_id,
    );
    expect(item).toMatchObject({ status: 'pending', max_effective_pct: '8.00', cap_pct: '5.00' });
    const decided = await call('post', `/api/approvals/${requested.approval_id}/decide`, manager, {
      approve: true,
      note: 'Fine',
    });
    expect(decided.status, JSON.stringify(decided.body)).toBe(200);
    expect(decided.body).toEqual({ status: 'approved' });

    // The cashier sees the decision and sells.
    const read = await call(
      'get',
      `/api/sales/discount-approvals/${requested.approval_id}`,
      cashier,
    );
    expect(read.status, JSON.stringify(read.body)).toBe(200);
    expect(DiscountApproval.parse(read.body)).toMatchObject({
      status: 'approved',
      decision_note: 'Fine',
      used: false,
    });
    const sold = await sell(cashier, body, 'ap-sale');
    expect(sold.status, JSON.stringify(sold.body)).toBe(201);
    expect(Sale.parse(sold.body)).toMatchObject({ discount_total: '91.20', total: '1048.80' });
    const used = await service
      .from('approvals')
      .select('entity_id')
      .eq('id', requested.approval_id)
      .single();
    expect(used.data?.entity_id).toBe(Sale.parse(sold.body).id);

    // Once only.
    const again = await sell(cashier, body, 'ap-again');
    expect(again.status).toBe(409);
    expect(code(again)).toBe('APPROVAL_INVALID');
    // The same key is the same sale and spends nothing more.
    const repeat = await sell(cashier, body, 'ap-sale');
    expect(repeat.status).toBe(201);
    expect(Sale.parse(repeat.body).id).toBe(Sale.parse(sold.body).id);
  });

  it('a request within the cap is not needed, and a pending one can be taken back', async () => {
    const within = await call('post', '/api/sales/discount-approvals', cashier, {
      branch_id: branch,
      lines: [{ product_id: tv, quantity: 1, discount: { type: 'percent', value: '4' } }],
      reason: 'Regular customer',
    });
    expect(within.status).toBe(400);
    expect(code(within)).toBe('APPROVAL_NOT_NEEDED');
    const asked = await call('post', '/api/sales/discount-approvals', cashier, {
      branch_id: branch,
      lines: [{ product_id: tv, quantity: 1, discount: { type: 'percent', value: '9' } }],
      reason: 'Regular customer',
    });
    expect(asked.status, JSON.stringify(asked.body)).toBe(201);
    const id = DiscountApprovalRequested.parse(asked.body).approval_id;
    const cancelled = await call('post', `/api/sales/discount-approvals/${id}/cancel`, cashier);
    expect(cancelled.status, JSON.stringify(cancelled.body)).toBe(200);
    expect(cancelled.body).toEqual({ status: 'cancelled' });
    const decide = await call('post', `/api/approvals/${id}/decide`, manager, { approve: true });
    expect(decide.status).toBe(409);
    expect(code(decide)).toBe('APPROVAL_NOT_PENDING');
  });

  it("another shop's manager can't decide the approval: 404", async () => {
    const asked = await call('post', '/api/sales/discount-approvals', cashier, {
      branch_id: branch,
      lines: [{ product_id: tv, quantity: 1, discount: { type: 'percent', value: '7' } }],
      reason: 'Regular customer',
    });
    expect(asked.status, JSON.stringify(asked.body)).toBe(201);
    const id = DiscountApprovalRequested.parse(asked.body).approval_id;
    const res = await call(
      'post',
      `/api/approvals/${id}/decide`,
      otherOwner,
      { approve: true },
      undefined,
      otherOrg,
    );
    expect(res.status, JSON.stringify(res.body)).toBe(404);
    expect(code(res)).toBe('APPROVAL_NOT_FOUND');
    const still = await service.from('approvals').select('status').eq('id', id).single();
    expect(still.data?.status).toBe('pending');
  });
});
