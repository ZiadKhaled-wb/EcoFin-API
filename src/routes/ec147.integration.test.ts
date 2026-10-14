import { createHash } from 'node:crypto';
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuthLoginResponse, DevicePaired, ErrorResponse, Shift } from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
const RUN = process.env.RUN_INTEGRATION === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
describe.skipIf(!RUN)('EC147 revoked shift device', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let org: string;
  let branch: string;
  let mainSafe: string;
  let chair: string;
  let device: string;
  let pos = '';
  let shiftId = '';
  let ip = 0;
  const key = (tag: string) => `ec147-${STAMP}-${tag}`;
  const call = (
    method: 'get' | 'post',
    path: string,
    token = cashier,
    body?: object,
    idempotencyKey?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.147.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set('x-device-token', pos);
    if (idempotencyKey) r.set('Idempotency-Key', idempotencyKey);
    return body ? r.send(body) : r;
  };
  const code = (r: request.Response) => ErrorResponse.parse(r.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.147.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `ec147.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.147.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'EC147 shop',
        tenant_slug: `ec147-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.147.${(++ip % 250) + 1}`)
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
    const cashierEmail = `ec147.cashier.${STAMP}@ecotech.test`;
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
      sku: 'EC147-CH',
      cash_price: '250.00',
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    chair = (p1.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: chair, quantity: 5 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const created = await call('post', '/api/devices', owner, {
      name: 'EC147 POS',
      branch_id: branch,
    });
    expect(created.status).toBe(201);
    device = created.body.id as string;
    const pairing = await call('post', `/api/devices/${device}/pairing-code`, owner);
    const paired = await call('post', '/api/devices/pair', cashier, {
      code: pairing.body.code as string,
    });
    expect(paired.status).toBe(200);
    pos = DevicePaired.parse(paired.body).device_token;
  }, 60_000);

  it('pair, sell, unpair: API and direct DB reject without a new sale', async () => {
    const opened = await call(
      'post',
      '/api/shifts',
      cashier,
      { branch_id: branch, opening_float: '0' },
      key('shift'),
    );
    expect(opened.status).toBe(201);
    shiftId = Shift.parse(opened.body).id;
    const body = { lines: [{ product_id: chair, quantity: 1 }], expected_total: '250.00' };
    expect((await call('post', '/api/sales', cashier, body, key('valid-sale'))).status).toBe(201);
    const before = await service.from('sales').select('*').eq('organization_id', org);
    expect(before.error).toBeNull();
    const oldToken = pos;
    pos = '';
    const unpaired = await call('post', `/api/devices/${device}/unpair`, owner);
    expect(unpaired.status).toBe(200);
    pos = oldToken;
    const refused = await call('post', '/api/sales', cashier, body, key('api-revoked'));
    expect(refused.status).toBe(403);
    expect(code(refused)).toBe('DEVICE_REVOKED');
    const env = getEnv();
    const direct = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: {
        headers: {
          Authorization: 'Bearer ' + cashier,
          'x-org-id': org,
          'x-device-id': device,
          'x-device-token-hash': createHash('sha256').update(oldToken).digest('hex'),
        },
      },
    });
    const rpc = await direct.rpc('post_sale', {
      p_lines: body.lines,
      p_expected_total: '250.00',
      p_idempotency_key: key('db-revoked'),
    });
    expect(rpc.error?.message).toContain('DEVICE_REVOKED');
    expect(rpc.error?.code).toBe('42501');
    const after = await service.from('sales').select('*').eq('organization_id', org);
    expect(after.error).toBeNull();
    expect(after.data).toEqual(before.data);
  }, 30_000);
  it('manager force close works with no device; ledger and warning audit match', async () => {
    pos = '';
    const refused = await call('post', `/api/shifts/${shiftId}/force-close`, cashier, {
      counted_cash: '240.00',
      reason: 'Lost POS',
    });
    expect(refused.status).toBe(403);
    expect(code(refused)).toBe('PERMISSION_DENIED');
    const closed = await call('post', `/api/shifts/${shiftId}/force-close`, owner, {
      counted_cash: '240.00',
      reason: 'Lost POS',
    });
    expect(closed.status, JSON.stringify(closed.body)).toBe(200);
    expect(Shift.parse(closed.body)).toMatchObject({
      status: 'closed',
      expected_cash: '250.00',
      counted_cash: '240.00',
      difference: '-10.00',
      device_revoked: true,
    });
    const safe = await service
      .from('cash_balances')
      .select('balance')
      .eq('cash_account_id', mainSafe)
      .single();
    expect(safe.error).toBeNull();
    expect(String(safe.data!.balance)).toBe('240');
    const ledger = await service
      .from('cash_movements')
      .select('amount')
      .eq('organization_id', org)
      .eq('cash_account_id', mainSafe);
    expect(ledger.error).toBeNull();
    expect(ledger.data).toHaveLength(1);
    expect(String(ledger.data![0]!.amount)).toBe('240');
    const audit = await service
      .from('audit_log')
      .select('severity,reason')
      .eq('organization_id', org)
      .eq('entity_id', shiftId)
      .eq('action', 'shift.force_closed');
    expect(audit.error).toBeNull();
    expect(audit.data).toEqual([{ severity: 'warning', reason: 'Lost POS' }]);
  });
});
