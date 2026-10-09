// U04 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh retail_pro shop's owner approves an invoice (10 TVs, 3 serialized phones), reads what
// can go back, posts a credit return twice with one key (one return), is refused above the
// returnable, then posts a cash return into the main safe; stock, the supplier balance and the
// safe each change once. A warehouse user can't return or read the accounts.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  PayableCashAccountList,
  PurchaseInvoice,
  PurchaseReturn,
  PurchaseReturnList,
  ReturnableInvoice,
  StockList,
  Supplier,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const TODAY = new Date().toISOString().slice(0, 10);

describe.skipIf(!RUN)('U04 purchase returns against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let warehouse: string;
  let org: string;
  let branch: string;
  let mainSafe: string;
  let supplierId: string;
  let tv: string;
  let phone: string;
  let invoice: PurchaseInvoice;
  let ip = 0;
  const call = (
    method: 'get' | 'post',
    path: string,
    token = owner,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.56.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.56.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const onHand = async (id: string) =>
    StockList.parse((await call('get', `/api/stock?branch_id=${branch}`)).body).items.find(
      (r) => r.product_id === id,
    )!.on_hand;
  const balance = async () =>
    Supplier.parse((await call('get', `/api/suppliers/${supplierId}`)).body).balance;
  const line = (id: string) => invoice.lines.find((l) => l.product_id === id)!;

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `u04.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.56.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'U04 shop',
        tenant_slug: `u04-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.56.${(++ip % 250) + 1}`)
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
    mainSafe = main.data!.default_cash_account_id as string;
    const whEmail = `u04.warehouse.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: whEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: whEmail,
        full_name: 'Warehouse',
        role: 'WAREHOUSE',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    warehouse = await login(whEmail);

    const supplier = await call('post', '/api/suppliers', owner, { name: 'Delta Supplies' });
    expect(supplier.status, JSON.stringify(supplier.body)).toBe(201);
    supplierId = Supplier.parse(supplier.body).id;
    const p1 = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: 'U04-TV',
      cash_price: '200.00',
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    tv = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', owner, {
      name_ar: 'موبايل',
      sku: 'U04-PH',
      cash_price: '6000.00',
      is_serialized: true,
    });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    phone = (p2.body as { id: string }).id;

    const created = await call(
      'post',
      '/api/purchase-invoices',
      owner,
      {
        supplier_id: supplierId,
        branch_id: branch,
        invoice_date: TODAY,
        lines: [
          { product_id: tv, quantity: 10, unit_cost: '100.00' },
          {
            product_id: phone,
            quantity: 3,
            unit_cost: '5000.00',
            serials: ['U04-SN-1', 'U04-SN-2', 'U04-SN-3'],
          },
        ],
      },
      `u04-it-pi-${STAMP}`,
    );
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const approved = await call(
      'post',
      `/api/purchase-invoices/${PurchaseInvoice.parse(created.body).id}/approve`,
    );
    expect(approved.status, JSON.stringify(approved.body)).toBe(200);
    invoice = PurchaseInvoice.parse(approved.body);
    expect(invoice.total).toBe('18240.00');
  }, 60_000);

  it('credit return once (same key twice), the cap, then a cash refund into the safe', async () => {
    const returnable = ReturnableInvoice.parse(
      (await call('get', `/api/purchase-invoices/${invoice.id}/returnable`)).body,
    );
    const tvLine = returnable.lines.find((l) => l.product_id === tv)!;
    const phoneLine = returnable.lines.find((l) => l.product_id === phone)!;
    expect(tvLine).toMatchObject({
      purchased: 10,
      returned: 0,
      returnable: 10,
      unit_cost: '100.00',
    });
    expect(phoneLine.units_in_stock.map((u) => u.serial)).toEqual([
      'U04-SN-1',
      'U04-SN-2',
      'U04-SN-3',
    ]);

    const body = {
      purchase_invoice_id: invoice.id,
      refund_mode: 'supplier_credit',
      reason: 'Damaged on arrival',
      lines: [
        { invoice_line_id: line(tv).id, quantity: 4 },
        { invoice_line_id: line(phone).id, unit_ids: [phoneLine.units_in_stock[0]!.unit_id] },
      ],
    };
    expect((await call('post', '/api/purchase-returns', owner, body)).status).toBe(400);
    const key = `u04-it-${STAMP}`;
    const posted = await call('post', '/api/purchase-returns', owner, body, key);
    expect(posted.status, JSON.stringify(posted.body)).toBe(201);
    const credit = PurchaseReturn.parse(posted.body);
    expect(credit).toMatchObject({
      invoice_number: invoice.number,
      refund_mode: 'supplier_credit',
      cash_account_id: null,
      subtotal: '5400.00',
      tax_total: '756.00',
      total: '6156.00',
    });
    expect(credit.number).toContain('PR');
    expect(credit.lines.find((l) => l.product_id === phone)!.serial).toBe('U04-SN-1');
    const again = await call('post', '/api/purchase-returns', owner, body, key);
    expect(again.status).toBe(201);
    expect(PurchaseReturn.parse(again.body)).toEqual(credit);
    expect(await onHand(tv)).toBe(6);
    expect(await onHand(phone)).toBe(2);
    expect(await balance()).toBe('12084.00');

    const tooMany = await call(
      'post',
      '/api/purchase-returns',
      owner,
      { ...body, lines: [{ invoice_line_id: line(tv).id, quantity: 7 }] },
      `u04-it-cap-${STAMP}`,
    );
    expect(tooMany.status).toBe(409);
    expect(code(tooMany)).toBe('RETURN_QTY_EXCEEDED');
    expect(ErrorResponse.parse(tooMany.body).error.details).toEqual({
      invoice_line_id: line(tv).id,
      returnable: 6,
    });
    expect(await onHand(tv)).toBe(6);

    const accounts = PayableCashAccountList.parse(
      (await call('get', `/api/purchasing/cash-accounts?branch_id=${branch}`)).body,
    );
    expect(accounts.items.find((a) => a.id === mainSafe)).toMatchObject({
      kind: 'safe',
      balance: '0.00',
    });
    const cashBody = {
      purchase_invoice_id: invoice.id,
      refund_mode: 'cash',
      cash_account_id: mainSafe,
      reason: 'Wrong model',
      lines: [{ invoice_line_id: line(tv).id, quantity: 2 }],
    };
    const noAccount = await call(
      'post',
      '/api/purchase-returns',
      owner,
      { ...cashBody, cash_account_id: undefined },
      `u04-it-noacc-${STAMP}`,
    );
    expect(noAccount.status).toBe(400);
    const refunded = await call(
      'post',
      '/api/purchase-returns',
      owner,
      cashBody,
      `u04-it-cash-${STAMP}`,
    );
    expect(refunded.status, JSON.stringify(refunded.body)).toBe(201);
    const cash = PurchaseReturn.parse(refunded.body);
    expect(cash).toMatchObject({ refund_mode: 'cash', cash_account_id: mainSafe, total: '228.00' });
    expect(await onHand(tv)).toBe(4);
    expect(await balance()).toBe('12084.00');
    const after = PayableCashAccountList.parse(
      (await call('get', `/api/purchasing/cash-accounts?branch_id=${branch}`)).body,
    );
    expect(after.items.find((a) => a.id === mainSafe)!.balance).toBe('228.00');

    const list = PurchaseReturnList.parse(
      (await call('get', `/api/purchase-returns?purchase_invoice_id=${invoice.id}`)).body,
    );
    expect(list.total).toBe(2);
    expect(list.items.map((r) => r.id).sort()).toEqual([credit.id, cash.id].sort());
    const read = await call('get', `/api/purchase-returns/${credit.id}`);
    expect(PurchaseReturn.parse(read.body)).toEqual(credit);
  });

  it('a warehouse user cannot return, read the returnable lines or the accounts', async () => {
    const denied = await call(
      'post',
      '/api/purchase-returns',
      warehouse,
      {
        purchase_invoice_id: invoice.id,
        refund_mode: 'supplier_credit',
        reason: 'Not allowed',
        lines: [{ invoice_line_id: line(tv).id, quantity: 1 }],
      },
      `u04-it-wh-${STAMP}`,
    );
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    expect(
      (await call('get', `/api/purchase-invoices/${invoice.id}/returnable`, warehouse)).status,
    ).toBe(403);
    expect(
      (await call('get', `/api/purchasing/cash-accounts?branch_id=${branch}`, warehouse)).status,
    ).toBe(403);
  });
});
