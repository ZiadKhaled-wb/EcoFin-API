import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  SubscriptionStatus,
  SubscriptionPaymentResponse,
  AdminSubscription,
} from '@ziadkhaled-wb/contracts';
import { randomUUID } from 'node:crypto';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
describe.skipIf(!RUN)('P05 subscriptions against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let admin: string;
  let owner: string;
  let org: string;
  let branch: string;
  let employee: string;
  let ip = 1;
  const email = `p05.owner.${STAMP}@ecotech.test`;
  function call(
    method: 'get' | 'post' | 'put',
    path: string,
    body: object = {},
    token = admin,
    key?: string,
  ) {
    let r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.8.${ip++}`)
      .set('Authorization', 'Bearer ' + token);
    if (token === owner) r = r.set('x-org-id', org);
    if (key) r = r.set('Idempotency-Key', key);
    return method === 'get' ? r : r.send(body);
  }
  async function login(identifier: string) {
    const res = await call('post', '/api/auth/login', { identifier, password: PASSWORD }, '');
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return AuthLoginResponse.parse(res.body);
  }
  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    admin = (await login('superadmin@ecotech.test')).accessToken;
    const created = await call('post', '/api/admin/shops', {
      name: 'P05 local shop',
      tenant_slug: `p05-${STAMP}`,
      plan_key: 'retail',
      owner: { full_name: 'P05 Owner', email },
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    org = created.body.organization_id;
    const accepted = await call(
      'post',
      '/api/auth/invites/accept',
      { token: await readInviteToken(email), password: PASSWORD },
      '',
    );
    expect(accepted.status).toBe(200);
    owner = (await login(email)).accessToken;
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    branch = main.data!.id;
    const second = await service
      .from('branches')
      .insert({ organization_id: org, code: 'B2', name: 'Second' });
    expect(second.error).toBeNull();
    const target = await service
      .from('employees')
      .insert({
        organization_id: org,
        full_name: 'Pending cashier',
        role: 'CASHIER',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(target.error).toBeNull();
    employee = target.data!.id;
  });
  it('downgrade blocked with typed details', async () => {
    const r = await call('post', `/api/admin/shops/${org}/plan`, {
      plan_key: 'starter',
      reason: 'downgrade',
    });
    expect(r.status).toBe(409);
    expect(r.body.error).toMatchObject({
      code: 'PLAN_DOWNGRADE_BLOCKED',
      details: [{ resource: 'branches', limit: 1, used: 2 }],
    });
  });
  it('parallel device inserts serialize the last seat', async () => {
    const seed = await service
      .from('devices')
      .insert(
        Array.from({ length: 5 }, (_, i) => ({
          organization_id: org,
          branch_id: branch,
          name: 'D' + i,
        })),
      );
    expect(seed.error).toBeNull();
    const results = await Promise.all(
      ['A', 'B'].map((name) =>
        service.from('devices').insert({ organization_id: org, branch_id: branch, name }),
      ),
    );
    expect(results.filter((r) => r.error === null)).toHaveLength(1);
    expect(results.find((r) => r.error)?.error?.message).toBe('PLAN_LIMIT_REACHED');
  });
  it('expired owner logs in, selects, reads and has writes denied', async () => {
    const r = await call('post', `/api/admin/shops/${org}/subscription-dates`, {
      start: '2000-01-01',
      end: '2000-01-02',
      reason: 'expired flow',
    });
    expect(r.status).toBe(200);
    owner = (await login(email)).accessToken;
    expect((await call('post', '/api/auth/select-shop', { orgId: org }, owner)).status).toBe(200);
    const status = await call('get', '/api/subscription', {}, owner);
    expect(status.status).toBe(200);
    expect(SubscriptionStatus.parse(status.body)).toMatchObject({
      read_only: true,
      state: 'expired',
    });
    expect((await call('get', '/api/auth/me', {}, owner)).status).toBe(200);
    const write = await call(
      'put',
      `/api/employees/${employee}/permissions`,
      { permissionKey: 'sale.void', granted: true, reason: 'expired proof' },
      owner,
    );
    expect(write.status).toBe(403);
    expect(write.body.error.code).toBe('SUBSCRIPTION_EXPIRED');
  });
  it('payment renews once, replays same id and restores write', async () => {
    const key = randomUUID();
    const body = {
      amount: '1200.25',
      period_start: '2026-10-01',
      period_end: '2099-10-31',
      reference: 'manual',
    };
    const first = await call('post', `/api/admin/shops/${org}/payments`, body, admin, key);
    expect(first.status, JSON.stringify(first.body)).toBe(201);
    const parsed = SubscriptionPaymentResponse.parse(first.body);
    const second = await call('post', `/api/admin/shops/${org}/payments`, body, admin, key);
    expect(second.status).toBe(201);
    expect(SubscriptionPaymentResponse.parse(second.body)).toEqual(parsed);
    const rows = await service
      .from('subscription_payments')
      .select('id')
      .eq('organization_id', org);
    expect(rows.data).toHaveLength(1);
    const detail = await call('get', `/api/admin/shops/${org}/subscription`);
    expect(detail.status).toBe(200);
    expect(AdminSubscription.parse(detail.body).payments[0]?.amount).toBe('1200.25');
    const write = await call(
      'put',
      `/api/employees/${employee}/permissions`,
      { permissionKey: 'sale.void', granted: true, reason: 'renewed proof' },
      owner,
    );
    expect(write.status, JSON.stringify(write.body)).toBe(200);
  });
  it.each([
    ['get', 'subscription', {}],
    ['post', 'plan', { plan_key: 'starter', reason: 'denied' }],
    ['post', 'subscription-dates', { start: '2026-10-01', end: null, reason: 'denied' }],
    ['post', 'payments', { amount: '500', period_start: '2026-10-01', period_end: '2026-10-31' }],
  ] as const)('owner denied %s %s', async (method, path, body) => {
    const r = await call(method, `/api/admin/shops/${org}/${path}`, body, owner, randomUUID());
    expect(r.status).toBe(403);
    expect(r.body.error.code).toBe('SUPER_ADMIN_REQUIRED');
  });
});
