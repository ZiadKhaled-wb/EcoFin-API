// U03 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner funds the main safe, approves two invoices of a supplier, pays 3 000 with
// two parallel POSTs of one key (one payment), pays the first invoice off, is refused above what
// is owed, and reverses the first payment; an accountant pays but can't reverse.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CashAccount,
  ErrorResponse,
  OpenSupplierInvoiceList,
  PurchaseInvoice,
  Supplier,
  SupplierPayment,
  SupplierPaymentList,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const day = (back: number) => new Date(Date.now() - back * 86_400_000).toISOString().slice(0, 10);

describe.skipIf(!RUN)('U03 supplier payments against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let accountant: string;
  let org: string;
  let branch: string;
  let mainSafe: string;
  let supplierId: string;
  let invoiceA: string;
  let invoiceB: string;
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
      .set('X-Forwarded-For', `198.18.55.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.55.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const safe = async () =>
    CashAccount.parse((await call('get', `/api/cash-accounts/${mainSafe}`)).body).balance;
  const owed = async (id: string) =>
    PurchaseInvoice.parse((await call('get', `/api/purchase-invoices/${id}`)).body).outstanding;
  const balance = async () =>
    Supplier.parse((await call('get', `/api/suppliers/${supplierId}`)).body).balance;
  async function approvedInvoice(tv: string, quantity: number, date: string, tag: string) {
    const created = await call(
      'post',
      '/api/purchase-invoices',
      owner,
      {
        supplier_id: supplierId,
        branch_id: branch,
        invoice_date: date,
        lines: [{ product_id: tv, quantity, unit_cost: '100.00' }],
      },
      `u03-it-pi-${tag}-${STAMP}`,
    );
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const id = PurchaseInvoice.parse(created.body).id;
    const approved = await call('post', `/api/purchase-invoices/${id}/approve`);
    expect(approved.status, JSON.stringify(approved.body)).toBe(200);
    return id;
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `u03.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.55.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'U03 shop',
        tenant_slug: `u03-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.55.${(++ip % 250) + 1}`)
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
    const accEmail = `u03.accountant.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: accEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: accEmail,
        full_name: 'Accountant',
        role: 'ACCOUNTANT',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    accountant = await login(accEmail);

    const supplier = await call('post', '/api/suppliers', owner, { name: 'Nile Traders' });
    expect(supplier.status, JSON.stringify(supplier.body)).toBe(201);
    supplierId = Supplier.parse(supplier.body).id;
    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: 'U03-TV',
      cash_price: '200.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    const tv = (product.body as { id: string }).id;
    invoiceA = await approvedInvoice(tv, 100, day(10), 'a');
    invoiceB = await approvedInvoice(tv, 50, day(1), 'b');
    const opened = await call(
      'post',
      `/api/cash-accounts/${mainSafe}/opening`,
      owner,
      { amount: '50000.00', note: 'Counted on day one' },
      `u03-it-open-${STAMP}`,
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(200);
  }, 60_000);

  it('two parallel POSTs with one key pay once; then the invoice is paid off; the owner reverses', async () => {
    const body = {
      supplier_id: supplierId,
      branch_id: branch,
      cash_account_id: mainSafe,
      amount: '3000.00',
      reference: 'TRX-1',
      allocations: [{ purchase_invoice_id: invoiceA, amount: '3000.00' }],
    };
    expect((await call('post', '/api/supplier-payments', owner, body)).status).toBe(400);
    const key = `u03-it-${STAMP}`;
    const [first, second] = await Promise.all([
      call('post', '/api/supplier-payments', owner, body, key),
      call('post', '/api/supplier-payments', owner, body, key),
    ]);
    expect(first.status, JSON.stringify(first.body)).toBe(201);
    expect(second.status, JSON.stringify(second.body)).toBe(201);
    const paid = SupplierPayment.parse(first.body);
    expect(SupplierPayment.parse(second.body)).toEqual(paid);
    expect(paid.number).toContain('SP');
    expect(paid).toMatchObject({ amount: '3000.00', reference: 'TRX-1' });
    expect(await safe()).toBe('47000.00');
    expect(await owed(invoiceA)).toBe('8400.00');
    expect(await balance()).toBe('14100.00');

    const rest = await call(
      'post',
      '/api/supplier-payments',
      owner,
      { ...body, amount: '8400.00', reference: null, allocations: undefined },
      `u03-it-rest-${STAMP}`,
    );
    expect(rest.status, JSON.stringify(rest.body)).toBe(201);
    expect(SupplierPayment.parse(rest.body).allocations).toEqual([
      expect.objectContaining({ purchase_invoice_id: invoiceA, amount: '8400.00' }),
    ]);
    expect(await owed(invoiceA)).toBe('0.00');
    const open = OpenSupplierInvoiceList.parse(
      (await call('get', `/api/supplier-payments/open-invoices?supplier_id=${supplierId}`)).body,
    );
    expect(open.total_outstanding).toBe('5700.00');
    expect(open.items.map((i) => i.purchase_invoice_id)).toEqual([invoiceB]);

    const tooMuch = await call(
      'post',
      '/api/supplier-payments',
      owner,
      { ...body, amount: '5700.01', allocations: undefined },
      `u03-it-over-${STAMP}`,
    );
    expect(tooMuch.status).toBe(409);
    expect(code(tooMuch)).toBe('PAYMENT_EXCEEDS_OUTSTANDING');
    expect(ErrorResponse.parse(tooMuch.body).error.details).toMatchObject({
      outstanding: '5700.00',
    });
    expect(await safe()).toBe('38600.00');

    const reversed = await call(
      'post',
      `/api/supplier-payments/${paid.id}/reverse`,
      owner,
      { reason: 'Paid the wrong supplier' },
      `u03-it-rev-${STAMP}`,
    );
    expect(reversed.status, JSON.stringify(reversed.body)).toBe(200);
    const reversal = SupplierPayment.parse(reversed.body);
    expect(reversal).toMatchObject({ reverses_payment_id: paid.id, amount: '3000.00' });
    expect(await safe()).toBe('41600.00');
    expect(await owed(invoiceA)).toBe('3000.00');
    expect(await balance()).toBe('8700.00');
    const again = await call(
      'post',
      `/api/supplier-payments/${paid.id}/reverse`,
      owner,
      { reason: 'Again' },
      `u03-it-rev2-${STAMP}`,
    );
    expect(again.status).toBe(409);
    expect(code(again)).toBe('PAYMENT_ALREADY_REVERSED');
    const read = SupplierPayment.parse(
      (await call('get', `/api/supplier-payments/${paid.id}`)).body,
    );
    expect(read.reversed_by_payment_id).toBe(reversal.id);

    const all = SupplierPaymentList.parse(
      (await call('get', `/api/supplier-payments?supplier_id=${supplierId}`)).body,
    );
    expect(all.total).toBe(3);
    const counted = SupplierPaymentList.parse(
      (
        await call(
          'get',
          `/api/supplier-payments?supplier_id=${supplierId}&include_reversals=false`,
        )
      ).body,
    );
    expect(counted.items.map((p) => p.amount)).toEqual(['8400.00']);
  });

  it('an accountant pays but cannot reverse', async () => {
    const paid = await call(
      'post',
      '/api/supplier-payments',
      accountant,
      { supplier_id: supplierId, branch_id: branch, cash_account_id: mainSafe, amount: '100.00' },
      `u03-it-acc-${STAMP}`,
    );
    expect(paid.status, JSON.stringify(paid.body)).toBe(201);
    const denied = await call(
      'post',
      `/api/supplier-payments/${SupplierPayment.parse(paid.body).id}/reverse`,
      accountant,
      { reason: 'Not the owner' },
      `u03-it-acc-rev-${STAMP}`,
    );
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('APPROVAL_OWNER_ONLY');
  });
});
