// N03 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts): a fresh shop
// sells two TVs on installments (N02); the contract search finds them; the preview shows what an
// amount pays; a cashier collects an installment in cash (two requests with one key: one receipt),
// then one payment on both contracts; the receipt reads back and prints (original, then copy);
// the owner reverses the latest collection the same day; a payment above what is left, a
// warehouse user, a cashier reversing and an unknown receipt are refused.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  Collection,
  CollectionPreview,
  ContractListPage,
  ErrorResponse,
  InstallmentSale,
  Shift,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('N03 collections against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let warehouse: string;
  let org: string;
  let branch: string;
  let tv: string;
  let customerId: string;
  let shift: Shift;
  let version: number;
  let first: InstallmentSale;
  let second: InstallmentSale;
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
      .set('X-Forwarded-For', `198.18.78.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  const key = (tag: string) => `n03-it-${tag}-${STAMP}`;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.78.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'CASHIER' | 'WAREHOUSE', tag: string) {
    const email = `n03.${tag}.${STAMP}@ecotech.test`;
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
        full_name: `N03 ${tag}`,
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
  async function sell(tag: string) {
    const sold = await call(
      'post',
      '/api/installments/sales',
      cashier,
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
      key(tag),
    );
    expect(sold.status, JSON.stringify(sold.body)).toBe(201);
    return InstallmentSale.parse(sold.body);
  }
  const cash = (contracts: { contract_id: string; amount: string }[], amount: string) => ({
    customer_id: customerId,
    contracts,
    payments: [{ method: 'cash', amount }],
  });

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `n03.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.78.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'N03 shop',
        tenant_slug: `n03-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.78.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;
    cashier = await addEmployee('CASHIER', 'cashier');
    warehouse = await addEmployee('WAREHOUSE', 'warehouse');

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
    });
    expect(published.status, JSON.stringify(published.body)).toBe(201);
    const current = await call('get', '/api/settings', owner);
    version = (current.body as { installment_policy: { version: number } }).installment_policy
      .version;
    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون',
      sku: `N03-TV-${STAMP}`,
      cash_price: '12000.00',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: tv, quantity: 5 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const created = await call('post', '/api/customers', owner, {
      full_name: `N03 customer ${STAMP}`,
      phones: ['01500000078'],
      national_id: '29001010100778',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    customerId = (created.body as { id: string }).id;
    const limit = await call('put', `/api/customers/${customerId}/credit-limit`, owner, {
      credit_limit: '100000.00',
      reason: 'N03 integration',
    });
    expect(limit.status, JSON.stringify(limit.body)).toBe(200);
    const opened = await call(
      'post',
      '/api/shifts',
      cashier,
      { branch_id: branch, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    shift = Shift.parse(opened.body);
    first = await sell('sale-1');
    second = await sell('sale-2');
  }, 120_000);

  it('finds the contracts and previews what an amount pays', async () => {
    const listed = await call(
      'get',
      `/api/contracts?q=${encodeURIComponent(first.contract.number)}`,
      cashier,
    );
    expect(listed.status, JSON.stringify(listed.body)).toBe(200);
    expect(ContractListPage.parse(listed.body).items.map((c) => c.id)).toEqual([first.contract.id]);
    const all = await call('get', `/api/contracts?customer_id=${customerId}`, cashier);
    expect(ContractListPage.parse(all.body).items).toHaveLength(2);

    const preview = await call(
      'get',
      `/api/contracts/${first.contract.id}/collection?amount=2500.00`,
      cashier,
    );
    expect(preview.status, JSON.stringify(preview.body)).toBe(200);
    const shown = CollectionPreview.parse(preview.body);
    expect(shown.due.remaining).toBe('12000.00');
    expect(shown.allocation?.lines.map((l) => l.amount)).toEqual(['1000.00', '1000.00', '500.00']);
  });

  it('collects once for one key, prints the receipt, then pays both contracts in one go', async () => {
    const body = cash([{ contract_id: first.contract.id, amount: '1000.00' }], '1000.00');
    const once = await call('post', '/api/collections', cashier, body, key('collect-1'));
    expect(once.status, JSON.stringify(once.body)).toBe(201);
    const receipt = Collection.parse(once.body);
    expect(receipt.contracts[0]?.after.remaining).toBe('11000.00');
    const again = await call('post', '/api/collections', cashier, body, key('collect-1'));
    expect(again.status).toBe(201);
    expect(Collection.parse(again.body).id).toBe(receipt.id);
    const moves = await service
      .from('cash_movements')
      .select('amount')
      .eq('shift_id', shift.id)
      .eq('source_id', receipt.id);
    expect(moves.data?.map((m) => Number(m.amount))).toEqual([1000]);

    const read = await call('get', `/api/collections/${receipt.id}`, cashier);
    expect(read.status, JSON.stringify(read.body)).toBe(200);
    expect(Collection.parse(read.body).number).toBe(receipt.number);
    const printed = await call('post', `/api/collections/${receipt.id}/prints`, cashier);
    expect(Collection.parse(printed.body).print).toEqual({ print_no: 1, copy: false });
    const copy = await call('post', `/api/collections/${receipt.id}/prints`, cashier);
    expect(Collection.parse(copy.body).print).toEqual({ print_no: 2, copy: true });

    const both = await call(
      'post',
      '/api/collections',
      cashier,
      cash(
        [
          { contract_id: first.contract.id, amount: '500.00' },
          { contract_id: second.contract.id, amount: '1000.00' },
        ],
        '1500.00',
      ),
      key('collect-both'),
    );
    expect(both.status, JSON.stringify(both.body)).toBe(201);
    const paid = Collection.parse(both.body);
    expect(paid.contracts.map((c) => [c.amount, c.after.remaining])).toEqual([
      ['500.00', '10500.00'],
      ['1000.00', '11000.00'],
    ]);
  });

  it('reverses the latest collection the same day (owner), not as a cashier', async () => {
    const taken = await call(
      'post',
      '/api/collections',
      cashier,
      cash([{ contract_id: second.contract.id, amount: '2000.00' }], '2000.00'),
      key('collect-wrong'),
    );
    expect(taken.status, JSON.stringify(taken.body)).toBe(201);
    const id = Collection.parse(taken.body).id;
    const denied = await call(
      'post',
      `/api/collections/${id}/reverse`,
      cashier,
      { reason: 'changed mind' },
      key('reverse-cashier'),
    );
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    const reversed = await call(
      'post',
      `/api/collections/${id}/reverse`,
      owner,
      { reason: 'changed mind' },
      key('reverse-owner'),
    );
    expect(reversed.status, JSON.stringify(reversed.body)).toBe(200);
    expect(Collection.parse(reversed.body).reversal?.reason).toBe('changed mind');
    const preview = await call('get', `/api/contracts/${second.contract.id}/collection`, cashier);
    expect(CollectionPreview.parse(preview.body).due.remaining).toBe('11000.00');
  });

  it('refuses a payment above what is left, a warehouse user and an unknown receipt', async () => {
    const above = await call(
      'post',
      '/api/collections',
      cashier,
      cash([{ contract_id: first.contract.id, amount: '10500.01' }], '10500.01'),
      key('above'),
    );
    expect(above.status).toBe(409);
    expect(code(above)).toBe('COLLECTION_EXCEEDS_REMAINING');
    const wh = await call(
      'post',
      '/api/collections',
      warehouse,
      cash([{ contract_id: first.contract.id, amount: '1.00' }], '1.00'),
      key('warehouse'),
    );
    expect(wh.status).toBe(403);
    const missing = await call(
      'get',
      '/api/collections/00000000-0000-4000-8000-0000000c0113',
      cashier,
    );
    expect(missing.status).toBe(404);
    expect(code(missing)).toBe('COLLECTION_NOT_FOUND');
  });
});
