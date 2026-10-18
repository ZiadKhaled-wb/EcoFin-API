// N05 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// sells three TVs on installments (N02) in the branch manager's shift. Over HTTP: a reschedule
// preview and the reschedule itself (the old schedule kept, the total unchanged, the same key
// again answers the same change), an early settlement with a waiver within the quote (one above it
// is refused with the max), its receipt can't be reversed, the owner writes off the third contract
// (a manager can't), a cashier is refused, the contract's history and the shop's list answer.
// (The arithmetic and every edge: supabase/tests/n05_contract_changes_test.sql.)
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ContractChangeHistory,
  ContractChangeListPage,
  ContractChangeResponse,
  ErrorResponse,
  InstallmentSale,
  ReschedulePreview,
  SettlementQuote,
  SettleResponse,
  subtractMoney,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('N05 contract changes against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let manager: string;
  let org: string;
  let branch: string;
  let tv: string;
  let version: number;
  const sales: InstallmentSale[] = [];
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
      .set('X-Forwarded-For', `198.18.80.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `n05-it-${tag}-${STAMP}`;
  const inDays = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.80.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'CASHIER' | 'BRANCH_MANAGER', tag: string) {
    const email = `n05.${tag}.${STAMP}@ecotech.test`;
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
        full_name: `N05 ${tag}`,
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
  async function balance(contractId: string) {
    const { data, error } = await service
      .from('v_contract_balances')
      .select('paid, remaining, status')
      .eq('contract_id', contractId)
      .single();
    expect(error).toBeNull();
    return data as { paid: number; remaining: number; status: string };
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `n05.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.80.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'N05 shop',
        tenant_slug: `n05-${STAMP}`,
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
    cashier = await addEmployee('CASHIER', 'cashier');
    manager = await addEmployee('BRANCH_MANAGER', 'manager');

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
      sku: `N05-TV-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: tv, quantity: 3 }] },
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
    for (const n of [1, 2, 3]) {
      const created = await call('post', '/api/customers', owner, {
        full_name: `N05 customer ${n} ${STAMP}`,
        phones: [`0150000080${n}`],
        national_id: `2900101010080${n}`,
      });
      expect(created.status, JSON.stringify(created.body)).toBe(201);
      const customerId = (created.body as { id: string }).id;
      const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
        credit_limit: '100000.00',
        reason: 'N05 integration',
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
        key(`sale-${n}`),
      );
      expect(sold.status, JSON.stringify(sold.body)).toBe(201);
      sales.push(InstallmentSale.parse(sold.body));
    }
  }, 180_000);

  it('reschedules: preview, then a new version with the same total; the old one is kept', async () => {
    const id = sales[0]!.contract.id;
    const plan = { installments_count: 5, frequency: 'monthly', first_due_date: inDays(20) };
    const preview = await call('post', `/api/contracts/${id}/reschedule/preview`, manager, plan);
    expect(preview.status, JSON.stringify(preview.body)).toBe(200);
    const p = ReschedulePreview.parse(preview.body);
    expect(p.remaining).toBe('12000.00');
    expect(p.lines).toHaveLength(5);
    expect(p.violations).toEqual([]);

    const refused = await call(
      'post',
      `/api/contracts/${id}/reschedule`,
      cashier,
      { ...plan, reason: 'Lost his job', expected_remaining: '12000.00' },
      key('r-cashier'),
    );
    expect(refused.status).toBe(403);
    expect(code(refused)).toBe('PERMISSION_DENIED');

    const before = await balance(id);
    const body = { ...plan, reason: 'Lost his job', expected_remaining: '12000.00' };
    const done = await call('post', `/api/contracts/${id}/reschedule`, manager, body, key('r1'));
    expect(done.status, JSON.stringify(done.body)).toBe(200);
    const r = ContractChangeResponse.parse(done.body);
    expect(r.change.kind).toBe('reschedule');
    expect(r.change.new_version).toBe(2);
    expect(r.contract.status).toBe('rescheduled');
    expect(r.contract.lines).toHaveLength(5);
    const again = await call('post', `/api/contracts/${id}/reschedule`, manager, body, key('r1'));
    expect(ContractChangeResponse.parse(again.body).change.id).toBe(r.change.id);
    const after = await balance(id);
    expect(Number(after.remaining)).toBe(Number(before.remaining));
    expect(Number(after.paid)).toBe(Number(before.paid));

    const history = await call('get', `/api/contracts/${id}/changes`, manager);
    expect(history.status, JSON.stringify(history.body)).toBe(200);
    const h = ContractChangeHistory.parse(history.body);
    expect(h.versions.map((v) => [v.version, v.superseded])).toEqual([
      [2, false],
      [1, true],
    ]);
    expect(h.versions[1]!.lines).toHaveLength(12);
  });

  it('settles early with a waiver within the quote; its receipt is not reversible', async () => {
    const id = sales[1]!.contract.id;
    const quoted = await call('get', `/api/contracts/${id}/settlement-quote`, manager);
    expect(quoted.status, JSON.stringify(quoted.body)).toBe(200);
    const q = SettlementQuote.parse(quoted.body);
    expect(q.remaining).toBe('12000.00');
    expect(q.suggested_waiver).toBe(q.future_profit); // waive_future_profit
    const pay = (waiver: string) => ({
      waiver,
      reason: 'Paid everything early',
      expected_remaining: q.remaining,
      payments: [{ method: 'cash', amount: subtractMoney(q.remaining, waiver) }],
    });

    const tooHigh = await call(
      'post',
      `/api/contracts/${id}/settle`,
      manager,
      pay('9999.00'),
      key('s-high'),
    );
    expect(tooHigh.status, JSON.stringify(tooHigh.body)).toBe(422);
    expect(code(tooHigh)).toBe('WAIVER_TOO_HIGH');
    expect(ErrorResponse.parse(tooHigh.body).error.details).toEqual({ max_waiver: q.max_waiver });

    const cashierQuote = await call('get', `/api/contracts/${id}/settlement-quote`, cashier);
    expect(cashierQuote.status).toBe(403);

    const settled = await call(
      'post',
      `/api/contracts/${id}/settle`,
      manager,
      pay(q.suggested_waiver),
      key('s1'),
    );
    expect(settled.status, JSON.stringify(settled.body)).toBe(200);
    const s = SettleResponse.parse(settled.body);
    expect(s.change.kind).toBe('early_settlement');
    expect(s.change.profit_waived).toBe(q.suggested_waiver);
    expect(s.collection.amount).toBe(subtractMoney(q.remaining, q.suggested_waiver));
    expect(s.collection.contracts[0]!.status).toBe('completed');
    expect((await balance(id)).status).toBe('completed');

    const reverse = await call(
      'post',
      `/api/collections/${s.collection.id}/reverse`,
      manager,
      { reason: 'Wrong customer' },
      key('s1-rev'),
    );
    expect(reverse.status).toBe(409);
    expect(code(reverse)).toBe('COLLECTION_NOT_REVERSIBLE');
    expect(ErrorResponse.parse(reverse.body).error.details).toMatchObject({
      reason: 'settlement',
    });
  });

  it('the owner writes off; a manager is refused; the list shows every change', async () => {
    const id = sales[2]!.contract.id;
    const body = { reason: 'Customer emigrated', expected_remaining: '12000.00' };
    const refused = await call(
      'post',
      `/api/contracts/${id}/write-off`,
      manager,
      body,
      key('wo-bm'),
    );
    expect(refused.status).toBe(403);
    const done = await call('post', `/api/contracts/${id}/write-off`, owner, body, key('wo'));
    expect(done.status, JSON.stringify(done.body)).toBe(200);
    const w = ContractChangeResponse.parse(done.body);
    expect(w.change.kind).toBe('write_off');
    expect(w.change.amount).toBe('12000.00');
    expect(w.contract.status).toBe('written_off');

    const list = await call('get', '/api/contract-changes?limit=10', owner);
    expect(list.status, JSON.stringify(list.body)).toBe(200);
    const page = ContractChangeListPage.parse(list.body);
    expect(page.items.map((i) => i.kind).sort()).toEqual([
      'early_settlement',
      'reschedule',
      'write_off',
    ]);
    const wo = await call('get', '/api/contract-changes?kind=write_off', owner);
    expect(ContractChangeListPage.parse(wo.body).items).toHaveLength(1);
    const bad = await call('get', '/api/contract-changes?kind=fee', owner);
    expect(bad.status).toBe(400);
    const cashierList = await call('get', '/api/contract-changes', cashier);
    expect(cashierList.status).toBe(403);
  });
});
