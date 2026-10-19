// N06 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// sells one TV on installments (N02) in the branch manager's shift. Over HTTP: the owner assigns
// the customer to a collector; the collector collects in the field with no shift (the cash goes to
// their wallet, the same key again answers the same receipt, an unassigned collector is refused);
// the wallet, its ledger and the route answer; the manager settles part of the wallet with a
// shortage (a stale balance is refused with the balance; the safe goes up by the handed amount
// only); a field collection reverses while its cash is in the wallet and not after it was handed
// in; the collector's overdue list is their own; the commission setting is 0.
// (Every rule and edge: supabase/tests/n06_collector_wallets_test.sql.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  Collection,
  CollectorRoute,
  Customer,
  ErrorResponse,
  InstallmentSale,
  MyWallet,
  OverdueListPage,
  WalletListResponse,
  WalletMovementPage,
  WalletSettlement,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('N06 collector wallets against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let manager: string;
  let collector: string;
  let other: string;
  let org: string;
  let branch: string;
  let tv: string;
  let version: number;
  let collectorId: string;
  let customerId: string;
  let contractId: string;
  let safeId: string;
  let walletId: string;
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
      .set('X-Forwarded-For', `198.18.81.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `n06-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.81.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'COLLECTOR' | 'BRANCH_MANAGER', tag: string) {
    const email = `n06.${tag}.${STAMP}@ecotech.test`;
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
        full_name: `N06 ${tag}`,
        role,
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    return { token: await login(email), id: emp.data!.id as string };
  }
  async function cash(accountId: string) {
    const { data, error } = await service
      .from('cash_balances')
      .select('balance')
      .eq('cash_account_id', accountId)
      .maybeSingle();
    expect(error).toBeNull();
    return Number(data?.balance ?? 0);
  }
  const field = (amount: string, tag: string, token = collector) =>
    call(
      'post',
      '/api/collections/field',
      token,
      {
        customer_id: customerId,
        contracts: [{ contract_id: contractId, amount }],
        payments: [{ method: 'cash', amount }],
      },
      key(tag),
    );

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `n06.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.81.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'N06 shop',
        tenant_slug: `n06-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.81.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    const safe = await service
      .from('cash_accounts')
      .select('id')
      .eq('organization_id', org)
      .eq('kind', 'safe')
      .single();
    expect(safe.error).toBeNull();
    safeId = safe.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;
    manager = (await addEmployee('BRANCH_MANAGER', 'manager')).token;
    const col = await addEmployee('COLLECTOR', 'collector');
    collector = col.token;
    collectorId = col.id;
    other = (await addEmployee('COLLECTOR', 'other')).token;
    const settings = await call('patch', '/api/settings', owner, {
      prices_include_vat: true,
      credit_min_score: 0,
    });
    expect(settings.status, JSON.stringify(settings.body)).toBe(200);
    const published = await call('post', '/api/settings/installment-policies', owner, {
      min_down_payment_pct: '10',
      max_months: 24,
      markup_tiers: [{ up_to_months: 24, pct: 20 }],
      allowed_frequencies: ['monthly'],
      rounding_step: '1.00',
      early_settlement_rule: 'waive_future_profit',
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    const current = await call('get', '/api/settings', owner);
    version = (current.body as { installment_policy: { version: number } }).installment_policy
      .version;
    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: `N06-TV-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: tv, quantity: 2 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const opened = await call(
      'post',
      '/api/shifts',
      manager,
      { branch_id: branch, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    const created = await call('post', '/api/customers', owner, {
      full_name: `N06 customer ${STAMP}`,
      phones: ['01500000801'],
      national_id: '29001010100801',
      city: 'Cairo',
      address: '5 Test Street',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    customerId = (created.body as { id: string }).id;
    const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '100000.00',
      reason: 'N06 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
    const sold = await call(
      'post',
      '/api/installments/sales',
      manager,
      {
        lines: [{ product_id: tv, quantity: 1 }],
        expected_total: '12000.00',
        customer_id: customerId,
        terms: {
          down_payment: '2000.00',
          installments_count: 12,
          frequency: 'monthly',
          policy_version: version,
        },
      },
      key('sale'),
    );
    expect(sold.status, JSON.stringify(sold.body)).toBe(201);
    contractId = InstallmentSale.parse(sold.body).contract.id;
  }, 180_000);

  it('assigns the customer; only the assigned collector (or a settler) may collect in the field', async () => {
    const refusedCollector = await call(
      'put',
      `/api/customers/${customerId}/collector`,
      collector,
      {
        employee_id: collectorId,
      },
    );
    expect(refusedCollector.status).toBe(403);
    expect(code(refusedCollector)).toBe('PERMISSION_DENIED');
    const invalid = await call('put', `/api/customers/${customerId}/collector`, owner, {
      employee_id: '00000000-0000-4000-8000-0000000c0117',
    });
    expect(invalid.status, JSON.stringify(invalid.body)).toBe(422);
    expect(code(invalid)).toBe('COLLECTOR_INVALID');
    const assigned = await call('put', `/api/customers/${customerId}/collector`, owner, {
      employee_id: collectorId,
      reason: 'East side',
    });
    expect(assigned.status, JSON.stringify(assigned.body)).toBe(200);
    expect(Customer.parse(assigned.body).collector?.id).toBe(collectorId);

    const notMine = await field('100.00', 'f-other', other);
    expect(notMine.status, JSON.stringify(notMine.body)).toBe(403);
    expect(code(notMine)).toBe('CUSTOMER_NOT_ASSIGNED');
  });

  it('collects in the field with no shift: the cash goes to the wallet, once', async () => {
    const before = await cash(safeId);
    const done = await field('1000.00', 'f1');
    expect(done.status, JSON.stringify(done.body)).toBe(201);
    const receipt = Collection.parse(done.body);
    expect(receipt.shift_id).toBeNull();
    expect(receipt.amount).toBe('1000.00');
    const again = await field('1000.00', 'f1');
    expect(again.status, JSON.stringify(again.body)).toBe(201);
    expect(Collection.parse(again.body).id).toBe(receipt.id);

    const mine = await call('get', '/api/wallets/me', collector);
    expect(mine.status, JSON.stringify(mine.body)).toBe(200);
    const w = MyWallet.parse(mine.body);
    expect(w.balance).toBe('1000.00');
    expect(w.today.count).toBe(1);
    expect(w.today.cash).toBe('1000.00');
    walletId = w.wallet!.id;
    expect(await cash(walletId)).toBe(1000);
    expect(await cash(safeId)).toBe(before);

    const ledger = await call('get', `/api/wallets/${walletId}/movements`, collector);
    expect(ledger.status, JSON.stringify(ledger.body)).toBe(200);
    const page = WalletMovementPage.parse(ledger.body);
    expect(page.items).toHaveLength(1);
    expect(page.items[0]!.type).toBe('collection');
    expect(page.items[0]!.balance_after).toBe('1000.00');
    const peek = await call('get', `/api/wallets/${walletId}/movements`, other);
    expect(peek.status).toBe(403);
  });

  it('lists the wallets for a settler only and reads the route', async () => {
    const refused = await call('get', '/api/wallets', collector);
    expect(refused.status).toBe(403);
    expect(code(refused)).toBe('PERMISSION_DENIED');
    const list = await call('get', '/api/wallets', manager);
    expect(list.status, JSON.stringify(list.body)).toBe(200);
    const rows = WalletListResponse.parse(list.body).items;
    expect(rows.map((r) => r.id)).toContain(walletId);
    const route = await call('get', '/api/collectors/route', collector);
    expect(route.status, JSON.stringify(route.body)).toBe(200);
    expect(CollectorRoute.parse(route.body).employee_id).toBe(collectorId);
    const foreign = await call('get', `/api/collectors/route?employee_id=${collectorId}`, other);
    expect(foreign.status).toBe(403);
    const overdue = await call('get', '/api/overdue', collector);
    expect(overdue.status, JSON.stringify(overdue.body)).toBe(200);
    expect(OverdueListPage.parse(overdue.body).items).toEqual([]);
  });

  it('reverses a field collection while the cash is in the wallet, not after it was handed in', async () => {
    const extra = await field('200.00', 'f2');
    expect(extra.status, JSON.stringify(extra.body)).toBe(201);
    const extraId = Collection.parse(extra.body).id;
    const reversed = await call(
      'post',
      `/api/collections/${extraId}/reverse`,
      manager,
      { reason: 'Wrong amount typed' },
      key('rev-f2'),
    );
    expect(reversed.status, JSON.stringify(reversed.body)).toBe(200);
    expect(await cash(walletId)).toBe(1000);
  });

  it('settles part of the wallet with a shortage, never twice', async () => {
    const stale = await call(
      'post',
      `/api/wallets/${walletId}/settle`,
      manager,
      { to_account_id: safeId, handed: '600.00', expected_balance: '900.00' },
      key('st-stale'),
    );
    expect(stale.status).toBe(409);
    expect(code(stale)).toBe('WALLET_BALANCE_CHANGED');
    expect((stale.body as { error: { details: { balance: string } } }).error.details.balance).toBe(
      '1000.00',
    );
    const noReason = await call(
      'post',
      `/api/wallets/${walletId}/settle`,
      manager,
      { to_account_id: safeId, handed: '600.00', shortage: '100.00', expected_balance: '1000.00' },
      key('st-noreason'),
    );
    expect(noReason.status).toBe(400);
    const cashierLike = await call(
      'post',
      `/api/wallets/${walletId}/settle`,
      collector,
      { to_account_id: safeId, handed: '600.00', expected_balance: '1000.00' },
      key('st-denied'),
    );
    expect(cashierLike.status).toBe(403);

    const safeBefore = await cash(safeId);
    const body = {
      to_account_id: safeId,
      handed: '600.00',
      shortage: '100.00',
      reason: 'Torn note',
      expected_balance: '1000.00',
    };
    const done = await call('post', `/api/wallets/${walletId}/settle`, manager, body, key('st1'));
    expect(done.status, JSON.stringify(done.body)).toBe(200);
    const s = WalletSettlement.parse(done.body);
    expect(s.handed).toBe('600.00');
    expect(s.shortage).toBe('100.00');
    expect(s.balance_after).toBe('300.00');
    const again = await call('post', `/api/wallets/${walletId}/settle`, manager, body, key('st1'));
    expect(again.status, JSON.stringify(again.body)).toBe(200);
    expect(WalletSettlement.parse(again.body).id).toBe(s.id);
    expect(await cash(walletId)).toBe(300);
    expect(await cash(safeId)).toBe(safeBefore + 600);

    // The first collection can't be reversed any more: a settlement came after it.
    const list = await call('get', `/api/wallets/${walletId}/movements`, manager);
    expect(list.status).toBe(200);
    const first = await service
      .from('payments')
      .select('id')
      .eq('organization_id', org)
      .eq('idempotency_key', key('f1'))
      .single();
    expect(first.error).toBeNull();
    const refused = await call(
      'post',
      `/api/collections/${first.data!.id as string}/reverse`,
      manager,
      { reason: 'Customer disputes it' },
      key('rev-f1'),
    );
    expect(refused.status).toBe(409);
    expect(code(refused)).toBe('COLLECTION_NOT_REVERSIBLE');
    expect((refused.body as { error: { details: { reason: string } } }).error.details.reason).toBe(
      'handed_in',
    );
  });

  it('has no collector commission', async () => {
    const current = await call('get', '/api/settings', owner);
    expect(current.status).toBe(200);
    expect((current.body as { collector_commission_pct: string }).collector_commission_pct).toBe(
      '0.00',
    );
    const rows = await service
      .from('collector_commissions')
      .select('id', { count: 'exact', head: true })
      .eq('organization_id', org);
    expect(rows.count).toBe(0);
  });
});
