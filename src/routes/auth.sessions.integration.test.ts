// Test-plan gaps (F04/F05): what happens to a live session when the employee changes, and a
// refresh right after a revocation. Against local Supabase; skipped unless RUN_INTEGRATION=1
// (env: see src/routes/auth.integration.test.ts).
//
// The employee is created here (unique per run) so changing its role or status can't disturb
// the other integration files, which run in parallel on the seed users. It is archived at the end.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  AuthMeResponse,
  AuthRefreshResponse,
  ErrorResponse,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const SHOP_ONE = 'd1000000-0000-0000-0000-000000000001';
const SHOP_ONE_BR1 = 'd2000000-0000-0000-0000-000000000011';
const PASSWORD = `Sessions-${Date.now()}!`;

// 198.18.0.0/15 (benchmarking range); the other integration files use other ranges.
let ipCounter = 0;
const nextIp = () => `198.18.0.${(ipCounter++ % 250) + 1}`;

describe.skipIf(!RUN)('live sessions when the employee changes (local Supabase)', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let employeeId: string;
  let authUserId: string;
  const email = `sessions.${Date.now()}@ecotech.test`;

  const me = (token: string) =>
    request(app)
      .get('/api/auth/me')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', `Bearer ${token}`);
  const post = (path: string, body: object, token?: string) => {
    const r = request(app).post(path).set('X-Forwarded-For', nextIp());
    return (token ? r.set('Authorization', `Bearer ${token}`) : r).send(body);
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login() {
    const res = await post('/api/auth/login', { identifier: email, password: PASSWORD });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return AuthLoginResponse.parse(res.body);
  }
  async function setEmployee(patch: Record<string, unknown>) {
    const { error } = await service.from('employees').update(patch).eq('id', employeeId);
    if (error) throw new Error(error.message);
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const created = await service.auth.admin.createUser({
      email,
      password: PASSWORD,
      email_confirm: true,
    });
    if (created.error) throw new Error(created.error.message);
    authUserId = created.data.user.id;
    const emp = await service
      .from('employees')
      .insert({
        organization_id: SHOP_ONE,
        auth_user_id: authUserId,
        full_name: 'Sessions Test',
        email,
        username: email.split('@')[0],
        role: 'CASHIER',
        default_branch_id: SHOP_ONE_BR1,
      })
      .select('id')
      .single();
    if (emp.error) throw new Error(emp.error.message);
    employeeId = emp.data.id;
    const branch = await service.from('employee_branches').insert({
      organization_id: SHOP_ONE,
      employee_id: employeeId,
      branch_id: SHOP_ONE_BR1,
    });
    if (branch.error) throw new Error(branch.error.message);
  });

  afterAll(async () => {
    if (employeeId) await setEmployee({ is_active: false, archived_at: new Date().toISOString() });
  });

  it('a role change applies to the very next request on the same token', async () => {
    const s = await login();
    const before = await me(s.accessToken);
    expect(before.status).toBe(200);
    expect(AuthMeResponse.parse(before.body).employee.role).toBe('CASHIER');

    await setEmployee({ role: 'ACCOUNTANT' });
    try {
      const after = await me(s.accessToken);
      expect(after.status).toBe(200);
      expect(AuthMeResponse.parse(after.body).employee.role).toBe('ACCOUNTANT');
    } finally {
      await setEmployee({ role: 'CASHIER' });
    }
  });

  it('disabling the employee blocks the live token at once, and a refresh does not get around it', async () => {
    const s = await login();
    expect((await me(s.accessToken)).status).toBe(200);

    await setEmployee({ is_active: false });
    try {
      const blocked = await me(s.accessToken);
      expect(blocked.status).toBe(403);
      expect(code(blocked)).toBe('ACCOUNT_DISABLED');

      // The refresh itself is a Supabase Auth call, but the new token meets the same gate.
      const refreshed = await post('/api/auth/refresh', { refreshToken: s.refreshToken });
      expect(refreshed.status).toBe(200);
      const fresh = AuthRefreshResponse.parse(refreshed.body);
      const stillBlocked = await me(fresh.accessToken);
      expect(stillBlocked.status).toBe(403);
      expect(code(stillBlocked)).toBe('ACCOUNT_DISABLED');

      // A new login is refused too.
      const relogin = await post('/api/auth/login', { identifier: email, password: PASSWORD });
      expect(relogin.status).toBe(403);
      expect(code(relogin)).toBe('ACCOUNT_DISABLED');
    } finally {
      await setEmployee({ is_active: true });
    }
    // Re-enabled: a fresh login works again.
    expect((await me((await login()).accessToken)).status).toBe(200);
  });

  it('archiving the employee blocks the live token at once', async () => {
    const s = await login();
    await setEmployee({ archived_at: new Date().toISOString() });
    try {
      const res = await me(s.accessToken);
      expect(res.status).toBe(403);
      expect(code(res)).toBe('ACCOUNT_DISABLED');
    } finally {
      await setEmployee({ archived_at: null });
    }
  });

  it('refresh immediately after logout is refused; another session of the same user still refreshes', async () => {
    const one = await login();
    const two = await login();

    expect((await post('/api/auth/logout', {}, one.accessToken)).status).toBe(200);
    const revoked = await post('/api/auth/refresh', { refreshToken: one.refreshToken });
    expect(revoked.status).toBe(401);
    expect(code(revoked)).toBe('TOKEN_INVALID');

    const other = await post('/api/auth/refresh', { refreshToken: two.refreshToken });
    expect(other.status).toBe(200);
  });

  it('refresh immediately after change-password: the other session is refused, this one refreshes', async () => {
    const one = await login();
    const two = await login();
    const newPassword = `${PASSWORD}-2`;

    const changed = await post(
      '/api/auth/change-password',
      { currentPassword: PASSWORD, newPassword },
      one.accessToken,
    );
    expect(changed.status).toBe(200);
    try {
      const other = await post('/api/auth/refresh', { refreshToken: two.refreshToken });
      expect(other.status).toBe(401);
      expect(code(other)).toBe('TOKEN_INVALID');
      expect((await post('/api/auth/refresh', { refreshToken: one.refreshToken })).status).toBe(
        200,
      );
    } finally {
      const { error } = await service.auth.admin.updateUserById(authUserId, {
        password: PASSWORD,
      });
      if (error) throw new Error(error.message);
    }
  });
});
