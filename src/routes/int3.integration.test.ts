// INT-3 (EC-131) against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// Sprint 3 end to end in one fresh shop. A purchase order becomes an invoice with IMEI units and
// raises stock and the supplier balance; a payment leaves the safe; a return takes stock and
// balance back; a transfer moves stock (and a unit) to a second branch; an adjustment fixes a
// difference; a manager opens a shift, pays an expense from it and closes it. At every step the
// stock view, the movement history, the low-stock alert, the supplier balance and the safe show
// the right numbers, and every balance equals the sum of its ledger.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  CashAccount,
  Expense,
  LowStockSummary,
  PurchaseInvoice,
  PurchaseOrder,
  Shift,
  StockList,
  StockMovementList,
  Supplier,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const cents = (money: string) => Math.round(Number(money) * 100);
const money = (c: number) => (c / 100).toFixed(2);

describe.skipIf(!RUN)('INT-3 stock and cash end to end against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let manager: string;
  let org: string;
  let main: string;
  let north: string;
  let safe: string;
  let supplierId: string;
  let phone: string;
  let chair: string;
  let ip = 0;
  const call = (
    method: 'get' | 'post' | 'put',
    path: string,
    token = owner,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.62.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  /** A call that must succeed; returns its body. */
  async function ok<T = Record<string, unknown>>(
    method: 'get' | 'post' | 'put',
    path: string,
    body?: object,
    key?: string,
    token = owner,
  ): Promise<T> {
    const res = await call(method, path, token, body, key);
    expect(res.status, `${method} ${path}: ${JSON.stringify(res.body)}`).toBeLessThan(300);
    return res.body as T;
  }
  const key = (tag: string) => `int3-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.62.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  /** The stock view row of a product in a branch. */
  async function stock(product: string, branch: string) {
    const rows = StockList.parse(await ok('get', `/api/stock?branch_id=${branch}&pageSize=100`));
    return rows.items.find((r) => r.product_id === product);
  }
  const onHand = async (product: string, branch: string) =>
    (await stock(product, branch))?.on_hand ?? 0;
  const owed = async () => Supplier.parse(await ok('get', `/api/suppliers/${supplierId}`)).balance;
  const inSafe = async () =>
    CashAccount.parse(await ok('get', `/api/cash-accounts/${safe}`)).balance;
  /** The low-stock alert of the chair in main, if it is low there. */
  const lowChair = async () =>
    LowStockSummary.parse(await ok('get', '/api/stock/low-summary?limit=20')).items.find(
      (i) => i.product_id === chair && i.branch_id === main,
    );

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `int3.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.62.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'INT-3 shop',
        tenant_slug: `int3-${STAMP}`,
        // Serials and more than one branch.
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.62.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const first = await service
      .from('branches')
      .select('id, default_cash_account_id')
      .eq('organization_id', org)
      .single();
    expect(first.error).toBeNull();
    main = first.data!.id as string;
    safe = first.data!.default_cash_account_id as string;
    north = (await ok<{ id: string }>('post', '/api/branches', { name: 'North', code: 'NTH' })).id;

    const managerEmail = `int3.manager.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: managerEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: managerEmail,
        full_name: 'Till Manager',
        role: 'BRANCH_MANAGER',
        default_branch_id: main,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: main });
    manager = await login(managerEmail);

    await ok(
      'post',
      `/api/cash-accounts/${safe}/opening`,
      { amount: '20000.00', note: 'Counted on day one' },
      key('opening'),
    );
    supplierId = Supplier.parse(await ok('post', '/api/suppliers', { name: 'Nile Traders' })).id;
    phone = (
      await ok<{ id: string }>('post', '/api/products', {
        name_ar: 'هاتف',
        sku: 'INT3-PH',
        cash_price: '5000.00',
        is_serialized: true,
      })
    ).id;
    chair = (
      await ok<{ id: string }>('post', '/api/products', {
        name_ar: 'كرسي',
        sku: 'INT3-CH',
        cash_price: '250.00',
      })
    ).id;
    // The main branch wants at least 5 chairs.
    await ok('put', `/api/stock/min-levels/${chair}`, { branch_id: main, min_stock: 5 });
  }, 90_000);

  it('purchase → stock → supplier → vault → transfer → adjustment → shift and expense', async () => {
    // Before anything arrives the chair is low in main (0 of 5).
    expect(await lowChair()).toMatchObject({ available: 0, min_level: 5, shortage: 5 });

    // 1. Purchase order → invoice with IMEI units → approved (U05, U02, I04).
    const po = PurchaseOrder.parse(
      await ok(
        'post',
        '/api/purchase-orders',
        {
          supplier_id: supplierId,
          branch_id: main,
          lines: [
            { product_id: phone, quantity: 3, expected_unit_cost: '3000.00' },
            { product_id: chair, quantity: 10, expected_unit_cost: '100.00' },
          ],
        },
        key('po'),
      ),
    );
    await ok('post', `/api/purchase-orders/${po.id}/send`);
    const draft = PurchaseInvoice.parse(
      await ok('post', `/api/purchase-orders/${po.id}/invoice`, {}, key('receive')),
    );
    const serials = [1, 2, 3].map((n) => `INT3-${STAMP}-${n}`);
    await ok('put', `/api/purchase-invoices/${draft.id}`, {
      lines: draft.lines.map((l) => ({
        product_id: l.product_id,
        quantity: l.quantity,
        unit_cost: l.unit_cost,
        po_line_id: l.po_line_id,
        ...(l.product_id === phone ? { serials } : {}),
      })),
    });
    const invoice = PurchaseInvoice.parse(
      await ok('post', `/api/purchase-invoices/${draft.id}/approve`),
    );
    expect(invoice.status).toBe('approved');
    const phoneLine = invoice.lines.find((l) => l.product_id === phone)!;
    const chairLine = invoice.lines.find((l) => l.product_id === chair)!;
    expect(phoneLine.unit_ids).toHaveLength(3);
    expect(PurchaseOrder.parse(await ok('get', `/api/purchase-orders/${po.id}`)).status).toBe(
      'received',
    );
    expect(await onHand(phone, main)).toBe(3);
    expect(await onHand(chair, main)).toBe(10);
    expect(await owed()).toBe(invoice.total);
    expect(await lowChair()).toBeUndefined();
    let balance = cents(invoice.total);

    // 2. A payment leaves the safe (U03, K01).
    await ok(
      'post',
      '/api/supplier-payments',
      { supplier_id: supplierId, branch_id: main, cash_account_id: safe, amount: '4000.00' },
      key('payment'),
    );
    balance -= 400_000;
    expect(await owed()).toBe(money(balance));
    expect(await inSafe()).toBe('16000.00');

    // 3. A return takes stock and balance back (U04): 2 chairs and one phone.
    const returnedUnit = phoneLine.unit_ids[0]!;
    const returned = await ok<{ total: string }>(
      'post',
      '/api/purchase-returns',
      {
        purchase_invoice_id: invoice.id,
        refund_mode: 'supplier_credit',
        reason: 'Arrived scratched',
        lines: [
          { invoice_line_id: chairLine.id, quantity: 2 },
          { invoice_line_id: phoneLine.id, unit_ids: [returnedUnit] },
        ],
      },
      key('return'),
    );
    balance -= cents(returned.total);
    expect(cents(returned.total)).toBeGreaterThan(0);
    expect(await owed()).toBe(money(balance));
    expect(await onHand(chair, main)).toBe(8);
    expect(await onHand(phone, main)).toBe(2);
    expect(await inSafe()).toBe('16000.00');

    // 4. A transfer moves 3 chairs and one phone to North (I03).
    const movedUnit = phoneLine.unit_ids[1]!;
    const transfer = await ok<{ id: string }>(
      'post',
      '/api/stock/transfers',
      {
        from_branch_id: main,
        to_branch_id: north,
        lines: [
          { product_id: chair, quantity: 3 },
          { product_id: phone, unit_id: movedUnit, quantity: 1 },
        ],
      },
      key('transfer'),
    );
    await ok('post', `/api/stock/transfers/${transfer.id}/send`);
    expect(await onHand(chair, main)).toBe(5);
    expect((await stock(chair, north))?.in_transit).toBe(3);
    await ok('post', `/api/stock/transfers/${transfer.id}/receive`, {});
    expect(await onHand(chair, north)).toBe(3);
    expect(await onHand(phone, main)).toBe(1);
    expect(await onHand(phone, north)).toBe(1);
    const unit = await ok<{ branch_id: string; status: string }>('get', `/api/units/${movedUnit}`);
    expect(unit).toMatchObject({ branch_id: north, status: 'in_stock' });

    // 5. A chair is lost: the adjustment fixes the difference (I02) and the alert comes back (I06).
    await ok(
      'post',
      '/api/stock/adjustments',
      { branch_id: main, reason: 'loss', lines: [{ product_id: chair, quantity: -1 }] },
      key('adjustment'),
    );
    expect(await stock(chair, main)).toMatchObject({ on_hand: 4, min_level: 5, low: true });
    expect(await lowChair()).toMatchObject({ available: 4, min_level: 5, shortage: 1 });

    // 6. The till: a shift with a float, an expense from it, closed with an exact count (K02, K03).
    const shift = Shift.parse(
      await ok(
        'post',
        '/api/shifts',
        { branch_id: main, opening_float: '500.00', vault_id: safe },
        key('shift'),
        manager,
      ),
    );
    expect(await inSafe()).toBe('15500.00');
    const category = await ok<{ id: string }>('post', '/api/expense-categories', {
      name: 'Transport',
    });
    const expense = Expense.parse(
      await ok(
        'post',
        '/api/expenses',
        { category_id: category.id, amount: '120.00', from_shift: true, note: 'Delivery van' },
        key('expense'),
        manager,
      ),
    );
    expect(expense.shift_id).toBe(shift.id);
    expect(
      Shift.parse(await ok('get', `/api/shifts/${shift.id}`, undefined, undefined, manager))
        .expected_cash,
    ).toBe('380.00');
    const closed = Shift.parse(
      await ok(
        'post',
        `/api/shifts/${shift.id}/close`,
        { counts: { '200': 1, '100': 1, '50': 1, '20': 1, '10': 1 }, vault_id: safe },
        undefined,
        manager,
      ),
    );
    expect(closed).toMatchObject({ status: 'closed', counted_cash: '380.00', difference: '0.00' });
    // 20 000 - 4 000 (payment) - 500 (float) + 380 (closing).
    expect(await inSafe()).toBe('15880.00');

    // Done when: the stock view and the movement history show the right numbers.
    const history = StockMovementList.parse(
      await ok('get', `/api/stock/movements?product_id=${chair}&branch_id=${main}&pageSize=100`),
    );
    expect(history.items.map((m) => [m.type, m.quantity]).reverse()).toEqual([
      ['purchase_in', 10],
      ['purchase_return_out', -2],
      ['transfer_out', -3],
      ['adjustment', -1],
    ]);
    expect(history.items.reduce((sum, m) => sum + m.quantity, 0)).toBe(4);
    const unitHistory = StockMovementList.parse(
      await ok('get', `/api/stock/movements?serial=${serials[1]}&pageSize=100`),
    );
    expect(unitHistory.items.map((m) => m.type).reverse()).toEqual([
      'purchase_in',
      'transfer_out',
      'transfer_in',
    ]);
    const view = StockList.parse(await ok('get', '/api/stock?pageSize=100'));
    expect(
      view.items
        .map((r) => [r.sku, r.branch_id === main ? 'main' : 'north', r.on_hand, r.in_transit])
        .sort(),
    ).toEqual([
      ['INT3-CH', 'main', 4, 0],
      ['INT3-CH', 'north', 3, 0],
      ['INT3-PH', 'main', 1, 0],
      ['INT3-PH', 'north', 1, 0],
    ]);
    expect(view.items.every((r) => r.on_hand >= 0 && r.available >= 0)).toBe(true);

    // Every balance equals the sum of its ledger (the caches are never written directly).
    const stockRows = await service
      .from('stock_movements')
      .select('product_id, branch_id, quantity')
      .eq('organization_id', org);
    expect(stockRows.error).toBeNull();
    for (const row of view.items) {
      const sum = (stockRows.data ?? [])
        .filter((m) => m.product_id === row.product_id && m.branch_id === row.branch_id)
        .reduce((total, m) => total + Number(m.quantity), 0);
      expect(sum, `${row.sku} in ${row.branch_id}`).toBe(row.on_hand);
    }
    const cashRows = await service
      .from('cash_movements')
      .select('cash_account_id, amount')
      .eq('organization_id', org);
    expect(cashRows.error).toBeNull();
    const balances = await service
      .from('cash_balances')
      .select('cash_account_id, balance')
      .eq('organization_id', org);
    expect(balances.error).toBeNull();
    expect(balances.data!.length).toBeGreaterThanOrEqual(2); // the safe and the manager's drawer
    for (const b of balances.data ?? []) {
      const sum = (cashRows.data ?? [])
        .filter((m) => m.cash_account_id === b.cash_account_id)
        .reduce((total, m) => total + cents(String(m.amount)), 0);
      expect(sum, `cash account ${b.cash_account_id}`).toBe(cents(String(b.balance)));
      expect(sum).toBeGreaterThanOrEqual(0);
    }
  }, 120_000);
});
