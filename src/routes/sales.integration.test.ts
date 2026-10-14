// S01 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop stocks chairs and one IMEI phone; a cashier can't sell without a shift, opens one,
// quotes a cart and sells it (two requests with one key: one sale); the shift, the stock and the
// unit follow; the same IMEI, a stale total, too many chairs and a cashier's own price are
// refused with their codes; S02: a sale paid half cash, half bank transfer posts each half to its
// own place and the shift shows both; closing the shift counts only the cash into the safe.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CashAccount,
  ErrorResponse,
  Sale,
  SalePaymentAccountList,
  SaleQuote,
  Shift,
  StockList,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('S01 sale core against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let org: string;
  let branch: string;
  let mainSafe: string;
  let chair: string;
  let phone: string;
  let unit: string;
  let ip = 0;
  // O03: the paired POS computer every request of this test comes from.
  let pos = '';
  const call = (
    method: 'get' | 'post',
    path: string,
    token = cashier,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.63.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const details = (res: request.Response) => ErrorResponse.parse(res.body).error.details;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.63.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const chairs = async () =>
    StockList.parse((await call('get', `/api/stock?branch_id=${branch}`, owner)).body).items.find(
      (r) => r.product_id === chair,
    )?.on_hand ?? 0;
  const key = (tag: string) => `s01-it-${tag}-${STAMP}`;

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `s01.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.63.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'S01 shop',
        tenant_slug: `s01-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.63.${(++ip % 250) + 1}`)
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
    pos = (await pairTestDevice(service, org, branch)).token;
    mainSafe = main.data!.default_cash_account_id as string;
    const cashierEmail = `s01.cashier.${STAMP}@ecotech.test`;
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
      sku: 'S01-CH',
      cash_price: '250.00',
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    chair = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', owner, {
      name_ar: 'هاتف',
      sku: 'S01-PH',
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
      { product_id: phone, branch_id: branch, cost: '3000.00', serials: [`S01-${STAMP}`] },
      key('units'),
    );
    expect(units.status, JSON.stringify(units.body)).toBe(201);
    unit = (units.body as { units: { id: string }[] }).units[0]!.id;
  }, 60_000);

  it('a cashier needs a shift, sells once for one key, and every refusal has its code', async () => {
    const cart = [
      { product_id: chair, quantity: 2 },
      { product_id: phone, quantity: 1, unit_id: unit },
    ];
    // No shift: no quote and no sale.
    const early = await call('post', '/api/sales/quote', cashier, { lines: cart });
    expect(early.status).toBe(409);
    expect(code(early)).toBe('SHIFT_REQUIRED');
    const noShift = await call(
      'post',
      '/api/sales',
      cashier,
      { lines: cart, expected_total: '5500.00' },
      key('early'),
    );
    expect(noShift.status).toBe(409);
    expect(code(noShift)).toBe('SHIFT_REQUIRED');

    const opened = await call(
      'post',
      '/api/shifts',
      cashier,
      { branch_id: branch, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    const shift = Shift.parse(opened.body);

    // The quote is the server's price; nothing is sold by it.
    const quoted = await call('post', '/api/sales/quote', cashier, { lines: cart });
    expect(quoted.status, JSON.stringify(quoted.body)).toBe(200);
    const quote = SaleQuote.parse(quoted.body);
    expect(quote).toMatchObject({
      prices_include_vat: true,
      total: '5500.00',
      tax_total: '675.44',
    });
    expect(quote.lines.map((l) => [l.unit_price, l.available])).toEqual([
      ['250.00', 5],
      ['5000.00', 1],
    ]);
    expect(await chairs()).toBe(5);

    // The request: the key, the confirmed total, no branch and no organization.
    const body = { lines: cart, expected_total: quote.total };
    expect((await call('post', '/api/sales', cashier, body)).status).toBe(400);
    expect(
      (await call('post', '/api/sales', cashier, { ...body, branch_id: branch }, key('branch')))
        .status,
    ).toBe(400);
    expect((await call('post', '/api/sales', cashier, { lines: cart }, key('total'))).status).toBe(
      400,
    );

    // TEST4: five genuinely concurrent submissions; all preserve one sale and its ledgers.
    const responses = await Promise.all(
      Array.from({ length: 5 }, () => call('post', '/api/sales', cashier, body, key('sale'))),
    );
    // Preserve S01's original two-response success assertions.
    expect(responses[0]?.status).toBe(201);
    expect(responses[1]?.status).toBe(201);
    const first = responses.find((r) => r.status === 201);
    expect(first, JSON.stringify(responses.map((r) => r.body))).toBeDefined();
    const sale = Sale.parse(first!.body);
    for (const response of responses) {
      expect([201, 409]).toContain(response.status);
      if (response.status === 201) expect(Sale.parse(response.body).id).toBe(sale.id);
    }
    const stored = await service
      .from('sales')
      .select('id')
      .eq('organization_id', org)
      .eq('idempotency_key', key('sale'));
    expect(stored.error).toBeNull();
    expect(stored.data).toEqual([{ id: sale.id }]);
    expect(sale).toMatchObject({
      total: '5500.00',
      tax_total: '675.44',
      shift_id: shift.id,
      customer_id: null,
      created_by_name: 'Mona Cashier',
    });
    expect(sale.number).toContain('-SL-');
    expect(sale.lines.map((l) => [l.sku, l.quantity, l.line_total])).toEqual([
      ['S01-CH', 2, '500.00'],
      ['S01-PH', 1, '5000.00'],
    ]);
    expect(sale.payments).toEqual([
      expect.objectContaining({ method: 'cash', amount: '5500.00', reference: null }),
    ]);
    // Stock, the unit and the shift moved once.
    expect(await chairs()).toBe(3);
    const sold = await call('get', `/api/units/${unit}`, owner);
    expect((sold.body as { status: string }).status).toBe('sold');
    const after = Shift.parse((await call('get', `/api/shifts/${shift.id}`)).body);
    expect(after.expected_cash).toBe('5500.00');
    expect(after.movements.filter((m) => m.type === 'sale')).toHaveLength(1);

    // Done when: the sold unit can't be sold again.
    const again = await call(
      'post',
      '/api/sales',
      cashier,
      { lines: [{ product_id: phone, quantity: 1, unit_id: unit }], expected_total: '5000.00' },
      key('again'),
    );
    expect(again.status).toBe(409);
    expect(code(again)).toBe('UNIT_NOT_AVAILABLE');
    // A stale total, more chairs than the branch holds, a cashier's own price.
    const stale = await call(
      'post',
      '/api/sales',
      cashier,
      { lines: [{ product_id: chair, quantity: 1 }], expected_total: '240.00' },
      key('stale'),
    );
    expect(stale.status).toBe(409);
    expect(code(stale)).toBe('PRICE_CHANGED');
    expect(details(stale)).toEqual({ expected_total: '240.00', total: '250.00' });
    const tooMany = await call(
      'post',
      '/api/sales',
      cashier,
      { lines: [{ product_id: chair, quantity: 4 }], expected_total: '1000.00' },
      key('many'),
    );
    expect(tooMany.status).toBe(409);
    expect(code(tooMany)).toBe('OUT_OF_STOCK');
    expect(details(tooMany)).toEqual({ product_id: chair, requested: 4, available: 3 });
    const cheaper = await call(
      'post',
      '/api/sales',
      cashier,
      {
        lines: [{ product_id: chair, quantity: 1, unit_price: '100.00' }],
        expected_total: '100.00',
      },
      key('cheap'),
    );
    expect(cheaper.status).toBe(403);
    expect(code(cheaper)).toBe('PRICE_OVERRIDE_DENIED');
    expect(await chairs()).toBe(3);

    // Reads: the cashier's own sale and the owner; an unknown id is 404.
    expect(Sale.parse((await call('get', `/api/sales/${sale.id}`)).body).number).toBe(sale.number);
    expect(Sale.parse((await call('get', `/api/sales/${sale.id}`, owner)).body).total).toBe(
      '5500.00',
    );
    const missing = await call('get', `/api/sales/${shift.id}`, owner);
    expect(missing.status).toBe(404);
    expect(code(missing)).toBe('SALE_NOT_FOUND');

    // S02 (D64): split payments. A shop-wide bank, listed by name for the cashier.
    const madeBank = await call('post', '/api/cash-accounts', owner, {
      name: `S02 bank ${STAMP}`,
      kind: 'bank',
      branch_id: null,
    });
    expect(madeBank.status, JSON.stringify(madeBank.body)).toBe(201);
    const bank = (madeBank.body as { id: string }).id;
    const accounts = SalePaymentAccountList.parse(
      (await call('get', '/api/sales/payment-accounts')).body,
    );
    expect(accounts.items).toEqual([{ id: bank, name: `S02 bank ${STAMP}` }]);
    const oneChair = [{ product_id: chair, quantity: 1 }];
    // Half cash, half transfer (201): each half posts to its own place.
    const split = await call(
      'post',
      '/api/sales',
      cashier,
      {
        lines: oneChair,
        expected_total: '250.00',
        payments: [
          { method: 'cash', amount: '125.00', tendered: '150.00' },
          { method: 'bank_transfer', amount: '125.00', cash_account_id: bank, reference: 'TRX-1' },
        ],
      },
      key('split'),
    );
    expect(split.status, JSON.stringify(split.body)).toBe(201);
    const splitSale = Sale.parse(split.body);
    expect(splitSale).toMatchObject({ paid_total: '250.00', change_total: '25.00' });
    expect(splitSale.payments.map((p) => [p.method, p.amount, p.reference, p.change])).toEqual([
      ['cash', '125.00', null, '25.00'],
      ['bank_transfer', '125.00', 'TRX-1', null],
    ]);
    expect(
      CashAccount.parse((await call('get', `/api/cash-accounts/${bank}`, owner)).body).balance,
    ).toBe('125.00');
    // The shift shows both halves; its expected cash counts the cash half only.
    const taken = Shift.parse((await call('get', `/api/shifts/${shift.id}`)).body);
    expect(taken.sales_total).toBe('5750.00');
    expect(taken.payment_totals).toEqual({
      cash: '5625.00',
      bank_transfer: '125.00',
      store_credit: '0.00',
    });
    expect(taken.expected_cash).toBe('5625.00');
    // A mismatch is 400 with both amounts and sells nothing; a missing reference never gets there.
    const mismatch = await call(
      'post',
      '/api/sales',
      cashier,
      {
        lines: oneChair,
        expected_total: '250.00',
        payments: [{ method: 'cash', amount: '100.00' }],
      },
      key('mismatch'),
    );
    expect(mismatch.status).toBe(400);
    expect(code(mismatch)).toBe('PAYMENT_TOTAL_MISMATCH');
    expect(details(mismatch)).toEqual({ total: '250.00', paid: '100.00' });
    const noReference = await call(
      'post',
      '/api/sales',
      cashier,
      {
        lines: oneChair,
        expected_total: '250.00',
        payments: [{ method: 'bank_transfer', amount: '250.00', cash_account_id: bank }],
      },
      key('noref'),
    );
    expect(noReference.status).toBe(400);
    expect(code(noReference)).toBe('VALIDATION_FAILED');
    expect(await chairs()).toBe(2);

    // Closing the shift counts only the cash half into the safe; then no more sales.
    const closed = await call('post', `/api/shifts/${shift.id}/close`, cashier, {
      counts: { '200': 28, '20': 1, '5': 1 },
      vault_id: mainSafe,
    });
    expect(closed.status, JSON.stringify(closed.body)).toBe(200);
    expect(Shift.parse(closed.body)).toMatchObject({ status: 'closed', difference: '0.00' });
    expect(
      CashAccount.parse((await call('get', `/api/cash-accounts/${mainSafe}`, owner)).body).balance,
    ).toBe('5625.00');
    const late = await call(
      'post',
      '/api/sales',
      cashier,
      { lines: [{ product_id: chair, quantity: 1 }], expected_total: '250.00' },
      key('late'),
    );
    expect(late.status).toBe(409);
    expect(code(late)).toBe('SHIFT_REQUIRED');

    // The whole shop still reconciles: totals of sales = payments = cash and bank movements.
    const sales = await service.from('sales').select('total').eq('organization_id', org);
    const allocations = await service
      .from('payment_allocations')
      .select('amount')
      .eq('organization_id', org);
    const moves = await service
      .from('cash_movements')
      .select('amount')
      .eq('organization_id', org)
      .eq('type', 'sale');
    const sum = (rows: { total?: unknown; amount?: unknown }[] | null) =>
      (rows ?? []).reduce((t, r) => t + Math.round(Number(r.total ?? r.amount) * 100), 0);
    expect([sales.data!.length, sum(sales.data), sum(allocations.data), sum(moves.data)]).toEqual([
      2, 575_000, 575_000, 575_000,
    ]);
  }, 90_000);
  it('TEST4: last unit on two devices has exactly one winner (10 rounds)', async () => {
    const secondDevice = await pairTestDevice(service, org, branch, 'TEST4 second POS');
    const secondLogin = await service.auth.admin.createUser({
      email: `test4.race.${STAMP}@ecotech.test`,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(secondLogin.error).toBeNull();
    const employee = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: secondLogin.data.user!.id,
        full_name: 'TEST4 Cashier Two',
        role: 'CASHIER',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(employee.error).toBeNull();
    expect(
      (
        await service
          .from('employee_branches')
          .insert({ organization_id: org, employee_id: employee.data!.id, branch_id: branch })
      ).error,
    ).toBeNull();
    const token = await login(`test4.race.${STAMP}@ecotech.test`);
    const second = (path: string, body: object, idem: string) =>
      request(app)
        .post(path)
        .set('X-Forwarded-For', `198.18.64.${(++ip % 250) + 1}`)
        .set('Authorization', 'Bearer ' + token)
        .set('x-org-id', org)
        .set(DEVICE_TOKEN_HEADER, secondDevice.token)
        .set('Idempotency-Key', idem)
        .send(body);
    expect(
      (
        await call(
          'post',
          '/api/shifts',
          cashier,
          { branch_id: branch, opening_float: '0' },
          key('race-shift'),
        )
      ).status,
    ).toBe(201);
    expect(
      (
        await second(
          '/api/shifts',
          { branch_id: branch, opening_float: '0' },
          key('race-shift-two'),
        )
      ).status,
    ).toBe(201);
    for (let round = 0; round < 10; round++) {
      const product = await call('post', '/api/products', owner, {
        name_ar: 'آخر وحدة',
        sku: `TEST4-LAST-${round}`,
        cash_price: '1.00',
      });
      expect(product.status, JSON.stringify(product.body)).toBe(201);
      const productId = String((product.body as { id: string }).id);
      expect(
        (
          await call(
            'post',
            '/api/stock/adjustments',
            owner,
            { branch_id: branch, reason: 'found', lines: [{ product_id: productId, quantity: 1 }] },
            key(`race-stock-${round}`),
          )
        ).status,
      ).toBe(201);
      const body = { lines: [{ product_id: productId, quantity: 1 }], expected_total: '1.00' };
      const responses = await Promise.all([
        call('post', '/api/sales', cashier, body, key(`race-a-${round}`)),
        second('/api/sales', body, key(`race-b-${round}`)),
      ]);
      expect(
        responses.map((r) => r.status).sort(),
        JSON.stringify(responses.map((r) => r.body)),
      ).toEqual([201, 409]);
      expect(code(responses.find((r) => r.status === 409)!)).toBe('OUT_OF_STOCK');
      const stock = await service
        .from('stock_levels')
        .select('on_hand')
        .eq('organization_id', org)
        .eq('product_id', productId)
        .eq('branch_id', branch);
      expect(stock.error).toBeNull();
      expect(stock.data).toEqual([{ on_hand: 0 }]);
      const sales = await service
        .from('sale_lines')
        .select('id')
        .eq('organization_id', org)
        .eq('product_id', productId);
      expect(sales.error).toBeNull();
      expect(sales.data).toHaveLength(1);
    }
  }, 60000);
  // BUG TEST4-B2: API rejects a client price instead of ignoring it and using the server price.
  it.fails('TEST4-B2: unprivileged client price is ignored by the API', async () => {
    const response = await call(
      'post',
      '/api/sales',
      cashier,
      { lines: [{ product_id: chair, quantity: 1, unit_price: '1.00' }], expected_total: '250.00' },
      key('ignored-client-price'),
    );
    expect(response.status, JSON.stringify(response.body)).toBe(201);
    expect(Sale.parse(response.body).lines[0]?.unit_price).toBe('250.00');
  });
});
