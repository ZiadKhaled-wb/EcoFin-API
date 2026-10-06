import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuthLoginResponse, EmployeesResponse } from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
const RUN = process.env['RUN_INTEGRATION'] === '1';
const password = 'LocalDev-Only-2026!';
const stamp = Date.now();
describe.skipIf(!RUN)('O02 staff against local Supabase', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let org: string;
  let branch: string;
  let ownerId: string;
  let cashier: string;
  let cashierId: string;
  let usernameId: string;
  let usernameToken: string;
  let ip = 0;
  const call = (
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    token = owner,
    body?: object,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.12.${++ip}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    return body ? r.send(body) : r;
  };
  async function login(identifier: string, pw = password, tenantSlug?: string) {
    const r = await call('post', '/api/auth/login', '', {
      identifier,
      password: pw,
      ...(tenantSlug ? { tenantSlug } : {}),
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `o02.owner.${stamp}@ecotech.test`;
    const shop = await call('post', '/api/admin/shops', admin, {
      name: 'O02 staff',
      tenant_slug: `o02-${stamp}`,
      plan_key: 'enterprise',
      owner: { full_name: 'Owner', email },
    });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id;
    ownerId = shop.body.owner_employee_id;
    expect(
      (
        await call('post', '/api/auth/invites/accept', '', {
          token: await readInviteToken(email),
          password,
        })
      ).status,
    ).toBe(200);
    owner = await login(email);
    const rows = await service.from('branches').select('id').eq('organization_id', org).single();
    branch = rows.data!.id;
  });
  it('owner creates emailed cashier, accepts and logs in', async () => {
    const email = `o02.cashier.${stamp}@ecotech.test`;
    const made = await call('post', '/api/employees', owner, {
      full_name: 'Cashier',
      email,
      role: 'CASHIER',
      branch_ids: [branch],
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    expect(made.body).toMatchObject({ delivery: 'email', email_sent: true });
    expect(made.body.invite_link).toBeUndefined();
    cashierId = made.body.employee_id;
    const accepted = await call('post', '/api/auth/invites/accept', '', {
      token: await readInviteToken(email),
      password,
    });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    cashier = await login(email);
    expect((await call('get', '/api/auth/me', cashier)).status).toBe(200);
  });
  it('F06 permission grant/revoke applies on the next request with the same token', async () => {
    expect((await call('get', '/api/audit', cashier)).status).toBe(403);
    expect(
      (
        await call('put', `/api/employees/${cashierId}/permissions`, owner, {
          permissionKey: 'audit.view',
          granted: true,
          reason: 'Read audit',
        })
      ).status,
    ).toBe(200);
    expect((await call('get', '/api/audit', cashier)).status).toBe(200);
    expect(
      (
        await call('put', `/api/employees/${cashierId}/permissions`, owner, {
          permissionKey: 'audit.view',
          granted: false,
          reason: 'Remove access',
        })
      ).status,
    ).toBe(200);
    expect((await call('get', '/api/audit', cashier)).status).toBe(403);
  });
  it('deactivation blocks the existing live token at once', async () => {
    expect(
      (
        await call('put', `/api/employees/${cashierId}/active`, owner, {
          active: false,
          reason: 'Leave',
        })
      ).status,
    ).toBe(200);
    const r = await call('get', '/api/auth/me', cashier);
    expect(r.status).toBe(403);
    expect(r.body.error.code).toBe('ACCOUNT_DISABLED');
    expect(
      (await call('put', `/api/employees/${cashierId}/active`, owner, { active: true })).status,
    ).toBe(200);
    expect((await call('get', '/api/auth/me', cashier)).status).toBe(200);
  });
  it('username-only invite accepts and login by username works without email delivery', async () => {
    const made = await call('post', '/api/employees', owner, {
      full_name: 'Username staff',
      username: 'username.staff',
      role: 'CASHIER',
      branch_ids: [branch],
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    usernameId = made.body.employee_id;
    expect(made.body.delivery).toBe('link');
    expect(made.body.email_sent).toBeUndefined();
    usernameToken = new URL(made.body.invite_link).hash.slice(7);
    const lookup = await call('post', '/api/auth/invites/lookup', '', { token: usernameToken });
    expect(lookup.body.login).toBe('username.staff');
    const accepted = await call('post', '/api/auth/invites/accept', '', {
      token: usernameToken,
      password,
    });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    expect(await login('username.staff', password, `o02-${stamp}`)).toBeTruthy();
  });
  it('reset changes password, old password fails, token replay returns 410', async () => {
    const reset = await call('post', `/api/employees/${usernameId}/password-reset`);
    expect(reset.status, JSON.stringify(reset.body)).toBe(200);
    const token = new URL(reset.body.reset_link).hash.slice(7);
    const result = await call('post', '/api/auth/password-reset/complete', '', {
      token,
      password: 'New-Staff-Password-2026!',
    });
    expect(result.status, JSON.stringify(result.body)).toBe(200);
    expect(result.body).toEqual({ login: 'username.staff', tenant_slug: `o02-${stamp}` });
    const old = await call('post', '/api/auth/login', '', {
      identifier: 'username.staff',
      tenantSlug: `o02-${stamp}`,
      password,
    });
    expect(old.status).toBe(401);
    expect(await login('username.staff', 'New-Staff-Password-2026!', `o02-${stamp}`)).toBeTruthy();
    const replay = await call('post', '/api/auth/password-reset/complete', '', {
      token,
      password: 'Another-Password-2026!',
    });
    expect(replay.status).toBe(410);
    expect(replay.body.error.code).toBe('RESET_USED');
  });
  it('linked identifiers are locked; list has no auth IDs or national IDs', async () => {
    const edit = await call('patch', `/api/employees/${usernameId}`, owner, {
      username: 'changed.name',
    });
    expect(edit.status).toBe(400);
    expect(edit.body.error.code).toBe('LOGIN_LOCKED');
    const list = await call('get', '/api/employees');
    expect(list.status).toBe(200);
    const rows = EmployeesResponse.parse(list.body);
    expect(rows.items[0]?.id).toBe(ownerId);
    expect(JSON.stringify(list.body)).not.toMatch(/national_id|auth_user_id|token_hash/);
  });
  it('protected targets and validation fail safely', async () => {
    for (const [method, suffix, body] of [
      ['patch', '', { role: 'CASHIER' }],
      ['put', '/active', { active: false, reason: 'x' }],
      ['post', '/password-reset', undefined],
    ] as const) {
      const r = await call(method, `/api/employees/${ownerId}${suffix}`, owner, body);
      expect(r.status).toBe(403);
      expect(r.body.error.code).toBe(suffix === '/active' ? 'FORBIDDEN' : 'TARGET_NOT_ALLOWED');
    }
    const invalid = await call('post', '/api/employees', owner, {
      full_name: 'Invalid',
      role: 'CASHIER',
      branch_ids: [branch],
    });
    expect(invalid.status).toBe(400);
  });
  it('manager with employee.manage cannot assign accountant defaults', async () => {
    const made = await call('post', '/api/employees', owner, {
      full_name: 'Manager',
      username: 'staff.manager',
      role: 'BRANCH_MANAGER',
      branch_ids: [branch],
      overrides: [{ key: 'employee.manage', granted: true }],
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    expect(
      (
        await call('post', '/api/auth/invites/accept', '', {
          token: new URL(made.body.invite_link).hash.slice(7),
          password,
        })
      ).status,
    ).toBe(200);
    const manager = await login('staff.manager', password, `o02-${stamp}`);
    const r = await call('post', '/api/employees', manager, {
      full_name: 'Escalation',
      username: 'accountant.staff',
      role: 'ACCOUNTANT',
      branch_ids: [branch],
    });
    expect(r.status, JSON.stringify(r.body)).toBe(403);
    expect(r.body.error.code).toBe('PERMISSION_ESCALATION');
  });
});
