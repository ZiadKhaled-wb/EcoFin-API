// S05 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// sells through the API and takes goods back: a cash return moves the drawer, the stock and the
// sale's status once; the installment sale of the slice's Done when (two payments, one item back)
// leaves 4 280.00 over 10 installments of 428.00; an exchange is paid for the difference; the
// refusals carry their codes. (Every rule and edge: supabase/tests/s05_returns_test.sql.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  SaleReturnable,
  SalesReturn,
  SalesReturnListResponse,
  SalesReturnQuote,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('S05 returns and exchanges against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let org: string;
  let main: string;
  let sofa: string;
  let table: string;
  let chair: string;
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
  const key = (tag: string) => `s05-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.88.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function level(product: string) {
    const { data, error } = await service
      .from('stock_levels')
      .select('on_hand')
      .eq('product_id', product)
      .eq('branch_id', main)
      .eq('stock_state', 'sellable')
      .maybeSingle();
    expect(error).toBeNull();
    return (data?.on_hand as number | undefined) ?? 0;
  }
  async function expectedCash() {
    const res = await call('get', '/api/shifts/current', owner);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return (res.body as { shift: { expected_cash: string } }).shift.expected_cash;
  }
  async function sell(tag: string, lines: object[], total: string) {
    const res = await call('post', '/api/sales', owner, { lines, expected_total: total }, key(tag));
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return (res.body as { id: string }).id;
  }
  async function returnable(saleId: string) {
    const res = await call('get', `/api/sales/${saleId}/returnable`, owner);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return SaleReturnable.parse(res.body);
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `s05.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.88.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'S05 shop',
        tenant_slug: `s05-${STAMP}`,
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

    const cashierEmail = `s05.cashier.${STAMP}@ecotech.test`;
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
        full_name: 'S05 Cashier',
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
    const product = async (name: string, sku: string, price: string) => {
      const res = await call('post', '/api/products', owner, {
        name_ar: name,
        sku: `S05-${sku}-${STAMP}`,
        cash_price: price,
      });
      expect(res.status, JSON.stringify(res.body)).toBe(201);
      return (res.body as { id: string }).id;
    };
    sofa = await product('كنبة', 'SOFA', '6000.00');
    table = await product('طاولة', 'TABLE', '4000.00');
    chair = await product('كرسي', 'CHAIR', '250.00');
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      {
        branch_id: main,
        reason: 'found',
        lines: [
          { product_id: sofa, quantity: 3 },
          { product_id: table, quantity: 3 },
          { product_id: chair, quantity: 10 },
        ],
      },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const created = await call('post', '/api/customers', owner, {
      full_name: `S05 customer ${STAMP}`,
      phones: ['01500000588'],
      national_id: '29001010100588',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    customerId = (created.body as { id: string }).id;
    const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '100000.00',
      reason: 'S05 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
    const opened = await call(
      'post',
      '/api/shifts',
      owner,
      { branch_id: main, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
  }, 120_000);

  it('a cash return moves the drawer, the stock and the sale status once; a replay is 200', async () => {
    const saleId = await sell('cash', [{ product_id: chair, quantity: 2 }], '500.00');
    const able = await returnable(saleId);
    expect(able.lines[0]!.returnable).toBe(2);
    expect(able.paid_by_method.cash).toBe('500.00');
    const line = able.lines[0]!.sale_line_id;
    const cashBefore = await expectedCash();
    const stockBefore = await level(chair);

    const quote = await call('post', '/api/returns/quote', owner, {
      sale_id: saleId,
      lines: [{ sale_line_id: line, quantity: 1 }],
    });
    expect(quote.status, JSON.stringify(quote.body)).toBe(200);
    expect(SalesReturnQuote.parse(quote.body).total).toBe('250.00');

    const body = {
      sale_id: saleId,
      lines: [{ sale_line_id: line, quantity: 1 }],
      refunds: [{ method: 'cash', amount: '250.00' }],
      reason: 'Customer changed his mind',
      expected_total: '250.00',
    };
    const made = await call('post', '/api/returns', owner, body, key('r1'));
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    const ret = SalesReturn.parse(made.body);
    expect(ret.number).toMatch(/-RT-/);
    const again = await call('post', '/api/returns', owner, body, key('r1'));
    expect(again.status).toBe(200);
    expect(SalesReturn.parse(again.body).id).toBe(ret.id);

    expect(Number(await expectedCash())).toBe(Number(cashBefore) - 250);
    expect(await level(chair)).toBe(stockBefore + 1);
    const details = await call('get', `/api/sales/${saleId}`, owner);
    expect((details.body as { status: string }).status).toBe('partially_returned');

    const one = await call('get', `/api/returns/${ret.id}`, owner);
    expect(SalesReturn.parse(one.body).lines).toHaveLength(1);
    const list = await call('get', `/api/returns?sale_id=${saleId}`, owner);
    expect(SalesReturnListResponse.parse(list.body).total_count).toBe(1);
    const printed = await call('post', `/api/returns/${ret.id}/receipt-prints`, owner);
    expect(printed.status).toBe(201);
    expect(printed.body).toEqual({ print_no: 1, copy: false });

    const over = await call(
      'post',
      '/api/returns',
      owner,
      { ...body, lines: [{ sale_line_id: line, quantity: 2 }], expected_total: '500.00' },
      key('over'),
    );
    expect(over.status).toBe(409);
    expect(code(over)).toBe('RETURN_QTY_EXCEEDED');
    const denied = await call('get', `/api/sales/${saleId}/returnable`, cashier);
    expect(denied.status).toBe(403);
  });

  it('Done when: one item back after two payments leaves 4 280.00 over 10 installments of 428.00', async () => {
    const inst = await call(
      'post',
      '/api/installments/sales',
      owner,
      {
        lines: [
          { product_id: sofa, quantity: 1 },
          { product_id: table, quantity: 1 },
        ],
        expected_total: '10000.00',
        customer_id: customerId,
        terms: {
          down_payment: '1000.00',
          installments_count: 12,
          frequency: 'monthly',
          policy_version: version,
        },
      },
      key('inst'),
    );
    expect(inst.status, JSON.stringify(inst.body)).toBe(201);
    const saleId = (inst.body as { sale: { id: string } }).sale.id;
    const contractId = (inst.body as { contract: { id: string } }).contract.id;
    for (const n of [1, 2]) {
      const paid = await call(
        'post',
        '/api/collections',
        owner,
        {
          customer_id: customerId,
          contracts: [{ contract_id: contractId, amount: '900.00' }],
          payments: [{ method: 'cash', amount: '900.00' }],
        },
        key(`pay-${n}`),
      );
      expect(paid.status, JSON.stringify(paid.body)).toBe(201);
    }
    const able = await returnable(saleId);
    expect(able.contract?.remaining).toBe('9000.00');
    const tableLine = able.lines.find((l) => l.product_id === table)!.sale_line_id;
    const lines = [{ sale_line_id: tableLine, quantity: 1 }];
    const quote = SalesReturnQuote.parse(
      (await call('post', '/api/returns/quote', owner, { sale_id: saleId, lines })).body,
    );
    expect(quote.contract).toMatchObject({
      credit: '4720.00',
      remaining_after: '4280.00',
      installments_left: 10,
      installment_amount: '428.00',
      overpaid: '0.00',
    });
    const made = await call(
      'post',
      '/api/returns',
      owner,
      { sale_id: saleId, lines, reason: 'Table did not fit', expected_total: '4000.00' },
      key('inst-return'),
    );
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    const ret = SalesReturn.parse(made.body);
    expect(ret.refund_method).toBe('contract_adjustment');
    expect(ret.contract_change).toMatchObject({ remaining_after: '4280.00', new_version: 2 });

    const { data, error } = await service
      .from('schedule_lines')
      .select('amount')
      .eq('contract_id', contractId)
      .eq('superseded', false);
    expect(error).toBeNull();
    expect(data!.map((l) => Number(l.amount))).toEqual(Array(10).fill(428));
    const account = await call('get', `/api/customers/${customerId}/account`, owner);
    expect(account.status, JSON.stringify(account.body)).toBe(200);
    expect((account.body as { balance: { open_balance: string } }).balance.open_balance).toBe(
      '4280.00',
    );
  });

  it('an exchange is paid for the difference; an installment sale can not be exchanged', async () => {
    const saleId = await sell('x', [{ product_id: chair, quantity: 1 }], '250.00');
    const line = (await returnable(saleId)).lines[0]!.sale_line_id;
    const cashBefore = await expectedCash();
    const made = await call(
      'post',
      '/api/returns',
      owner,
      {
        sale_id: saleId,
        kind: 'exchange',
        lines: [{ sale_line_id: line, quantity: 1 }],
        reason: 'Wants the table instead',
        expected_total: '250.00',
        new_sale: {
          lines: [{ product_id: table, quantity: 1 }],
          expected_total: '4000.00',
          payments: [{ method: 'cash', amount: '3750.00' }],
        },
      },
      key('exchange'),
    );
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    const ret = SalesReturn.parse(made.body);
    expect(ret.kind).toBe('exchange');
    expect(ret.exchange_sale?.total).toBe('4000.00');
    expect(Number(await expectedCash())).toBe(Number(cashBefore) + 3750);
  });
});
