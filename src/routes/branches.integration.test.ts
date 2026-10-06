import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  BranchList,
  ManagedBranchList,
  BranchDetail,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
describe.skipIf(!RUN)('O01 branches against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let admin: string;
  let owner: string;
  let cashier: string;
  let org: string;
  let main: string;
  let ownerEmployee: string;
  let second: string;
  let ip = 0;
  const call = (
    method: 'get' | 'post' | 'patch',
    path: string,
    token = owner,
    body?: object,
    shop = org,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.9.${++ip}`)
      .set('Authorization', 'Bearer ' + token);
    if (shop) r.set('x-org-id', shop);
    return body ? r.send(body) : r;
  };
  async function login(email: string) {
    const r = await call('post', '/api/auth/login', '', { identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function provision(suffix: string, plan = 'retail') {
    const email = `o01.${suffix}.${STAMP}@ecotech.test`;
    const c = await call('post', '/api/admin/shops', admin, {
      name: 'O01 ' + suffix,
      tenant_slug: `o01-${suffix}-${STAMP}`,
      plan_key: plan,
      owner: { full_name: 'Owner', email },
    });
    expect(c.status, JSON.stringify(c.body)).toBe(201);
    expect(
      (
        await call('post', '/api/auth/invites/accept', '', {
          token: await readInviteToken(email),
          password: PASSWORD,
        })
      ).status,
    ).toBe(200);
    return { org: c.body.organization_id as string, token: await login(email) };
  }
  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    admin = await login('superadmin@ecotech.test');
    const shop = await provision('owner');
    org = shop.org;
    owner = shop.token;
    const b = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(b.error).toBeNull();
    main = b.data!.id;
    const e = await service
      .from('employees')
      .select('id')
      .eq('organization_id', org)
      .eq('role', 'OWNER')
      .single();
    expect(e.error).toBeNull();
    ownerEmployee = e.data!.id;
    const email = `o01.cashier.${STAMP}@ecotech.test`;
    const u = await service.auth.admin.createUser({
      email,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(u.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: u.data.user!.id,
        email,
        full_name: 'Cashier',
        role: 'CASHIER',
        default_branch_id: main,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    expect(
      (
        await service
          .from('employee_branches')
          .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: main })
      ).error,
    ).toBeNull();
    cashier = await login(email);
  });
  it('owner creates a normalized branch with safe and sees it in both lists', async () => {
    const r = await call('post', '/api/branches', owner, { name: 'Second', code: 'b2' });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    second = r.body.id;
    const list = BranchList.parse((await call('get', '/api/branches')).body);
    expect(list[0]?.id).toBe(main);
    expect(list.map((b) => b.id)).toContain(second);
    const managed = ManagedBranchList.parse((await call('get', '/api/branches/manage')).body);
    expect(managed.find((b) => b.id === second)?.default_vault?.name).toBe('خزنة Second');
  });
  it('owner edits, deactivates clean branch and reactivates', async () => {
    const edit = await call('patch', `/api/branches/${second}`, owner, { name: 'Edited' });
    expect(edit.status, JSON.stringify(edit.body)).toBe(200);
    expect(BranchDetail.parse(edit.body).code).toBe('B2');
    expect(
      (await call('post', `/api/branches/${second}/deactivate`, owner, { reason: 'clean' })).status,
    ).toBe(200);
    expect(
      BranchList.parse((await call('get', '/api/branches')).body).map((b) => b.id),
    ).not.toContain(second);
    expect((await call('post', `/api/branches/${second}/reactivate`)).status).toBe(200);
    expect(BranchList.parse((await call('get', '/api/branches')).body).map((b) => b.id)).toContain(
      second,
    );
  });
  it('cashier sees assigned branch only and is denied every management route', async () => {
    expect(
      BranchList.parse((await call('get', '/api/branches', cashier)).body).map((b) => b.id),
    ).toEqual([main]);
    for (const [method, path, body] of [
      ['get', '/api/branches/manage', undefined],
      ['get', `/api/branches/${second}`, undefined],
      ['post', '/api/branches', { name: 'No', code: 'B3' }],
      ['patch', `/api/branches/${second}`, { name: 'No' }],
      ['get', `/api/branches/${second}/deactivation-check`, undefined],
      ['post', `/api/branches/${second}/deactivate`, { reason: 'No' }],
      ['post', `/api/branches/${second}/reactivate`, undefined],
    ] as const) {
      const r = await call(method, path, cashier, body);
      expect(r.status, JSON.stringify(r.body)).toBe(403);
      expect(r.body.error.code).toBe('PERMISSION_DENIED');
    }
  });
  it('all foreign branch-id routes reject with 404 and change nothing', async () => {
    const foreign = 'd2000000-0000-0000-0000-000000000021';
    const before = await service
      .from('branches')
      .select('name,is_active')
      .eq('id', foreign)
      .single();
    expect(before.error).toBeNull();
    for (const [method, suffix, body] of [
      ['get', '', undefined],
      ['patch', '', { name: 'Hijack' }],
      ['get', '/deactivation-check', undefined],
      ['post', '/deactivate', { reason: 'Hijack', confirm: true }],
      ['post', '/reactivate', undefined],
    ] as const) {
      const r = await call(method, `/api/branches/${foreign}${suffix}`, owner, body);
      expect(r.status, JSON.stringify(r.body)).toBe(404);
      expect(r.body.error.code).toBe('BRANCH_NOT_FOUND');
    }
    const row = await service.from('branches').select('name,is_active').eq('id', foreign).single();
    expect(row.error).toBeNull();
    expect(row.data).toEqual(before.data);
  });
  it('open shift requires confirmation and keeps counts in decimal format', async () => {
    const d = await service
      .from('cash_accounts')
      .insert({ organization_id: org, branch_id: second, name: 'Test drawer', kind: 'drawer' })
      .select('id')
      .single();
    expect(d.error).toBeNull();
    const shift = await service
      .from('shifts')
      .insert({
        organization_id: org,
        number: `B2-SH-26-${STAMP}`,
        branch_id: second,
        employee_id: ownerEmployee,
        drawer_account_id: d.data!.id,
        idempotency_key: `o01-shift-${STAMP}`,
      });
    expect(shift.error).toBeNull();
    const r = await call('post', `/api/branches/${second}/deactivate`, owner, {
      reason: 'shift warning',
    });
    expect(r.status).toBe(409);
    expect(r.body.error).toMatchObject({
      code: 'BRANCH_DEACTIVATE_NEEDS_CONFIRM',
      details: { open_shifts: 1, stock_units: 0, cash_balance: '0.00' },
    });
    expect(
      (
        await call('post', `/api/branches/${second}/deactivate`, owner, {
          reason: 'accept warning',
          confirm: true,
        })
      ).status,
    ).toBe(200);
  });
  it('starter second branch is blocked without partial safe', async () => {
    const s = await provision('starter', 'starter');
    const r = await call('post', '/api/branches', s.token, { name: 'Extra', code: 'B2' }, s.org);
    expect(r.status).toBe(409);
    expect(r.body.error.code).toBe('PLAN_LIMIT_REACHED');
    const rows = await service.from('cash_accounts').select('id').eq('organization_id', s.org);
    expect(rows.data).toHaveLength(1);
  });
});
