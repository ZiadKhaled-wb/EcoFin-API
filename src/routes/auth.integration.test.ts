// F04 against local Supabase: the real app (in-process, supertest) + local GoTrue + Postgres.
// Skipped unless RUN_INTEGRATION=1. Needs `npm run db:reset` (seeds) and the local env:
//   RUN_INTEGRATION=1 SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<local anon key> \
//   SUPABASE_SERVICE_ROLE_KEY=<local service role key> FRONTEND_URL=http://localhost:5173 \
//   npx vitest run src/routes/auth.integration.test.ts
// Keys: `npx -y supabase@2.119.0 status -o json`. Mailpit must be on http://127.0.0.1:54324.
// Each request gets its own X-Forwarded-For so the per-IP limiters don't interfere.
import { describe, it, expect, beforeAll } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  AuthMeResponse,
  AuthSelectShopResponse,
  AuthSession,
  ErrorResponse,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const SHOP_ONE = 'd1000000-0000-0000-0000-000000000001';
const SHOP_TWO = 'd1000000-0000-0000-0000-000000000002';
const MAILPIT = process.env['MAILPIT_URL'] ?? 'http://127.0.0.1:54324';

let ipCounter = 10;
const nextIp = () => `198.51.100.${(ipCounter++ % 240) + 10}`;

describe.skipIf(!RUN)('F04 auth against local Supabase', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;

  beforeAll(() => {
    const env = getEnv();
    app = createApp({ env });
    // Test-only reads of audit_log / login_attempts.
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  });

  const post = (path: string, body: object, token?: string, orgId?: string) => {
    let r = request(app).post(path).set('X-Forwarded-For', nextIp()).send(body);
    if (token) r = r.set('Authorization', `Bearer ${token}`);
    if (orgId) r = r.set('x-org-id', orgId);
    return r;
  };
  const me = (token: string, orgId?: string) => {
    let r = request(app)
      .get('/api/auth/me')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', `Bearer ${token}`);
    if (orgId) r = r.set('x-org-id', orgId);
    return r;
  };
  async function login(identifier: string, password = PASSWORD, tenantSlug?: string) {
    const res = await post('/api/auth/login', {
      identifier,
      password,
      ...(tenantSlug ? { tenantSlug } : {}),
    });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return AuthLoginResponse.parse(res.body);
  }
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;

  async function auditCount(employeeId: string, action: string): Promise<number> {
    const { count, error } = await service
      .from('audit_log')
      .select('id', { count: 'exact', head: true })
      .eq('employee_id', employeeId)
      .eq('action', action);
    if (error) throw new Error(error.message);
    return count ?? 0;
  }

  it('two users from two shops log in one after the other; each /me runs as its own user', async () => {
    const one = await login('owner.one@ecotech.test');
    const two = await login('owner.two', PASSWORD, 'dev-shop-two');
    expect(one.shops.map((s) => s.orgId)).toEqual([SHOP_ONE]);
    expect(two.shops.map((s) => s.orgId)).toEqual([SHOP_TWO]);

    // Interleaved on purpose: no request may see the other's session.
    for (const [token, org, name] of [
      [one.accessToken, SHOP_ONE, 'Owner One'],
      [two.accessToken, SHOP_TWO, 'Owner Two'],
      [one.accessToken, SHOP_ONE, 'Owner One'],
    ] as const) {
      const res = await me(token);
      expect(res.status).toBe(200);
      const body = AuthMeResponse.parse(res.body);
      expect(body.org.id).toBe(org);
      expect(body.employee.fullName).toBe(name);
    }
  });

  it('one login in two shops: selection needed without x-org-id, shop-B role with it, refused elsewhere', async () => {
    const multi = await login('multi.shop@ecotech.test');
    expect(multi.requiresShopSelection).toBe(true);
    expect(multi.shops.map((s) => s.orgId).sort()).toEqual([SHOP_ONE, SHOP_TWO]);

    const noHeader = await me(multi.accessToken);
    expect(noHeader.status).toBe(400);
    expect(code(noHeader)).toBe('SHOP_SELECTION_REQUIRED');

    const inB = await me(multi.accessToken, SHOP_TWO);
    expect(inB.status).toBe(200);
    const bodyB = AuthMeResponse.parse(inB.body);
    expect(bodyB.org.id).toBe(SHOP_TWO);
    expect(bodyB.employee.role).toBe('ACCOUNTANT');

    const inA = AuthMeResponse.parse((await me(multi.accessToken, SHOP_ONE)).body);
    expect(inA.employee.role).toBe('CASHIER');

    const elsewhere = await me(multi.accessToken, 'ffffffff-ffff-4fff-8fff-ffffffffffff');
    expect(elsewhere.status).toBe(403);
    expect(code(elsewhere)).toBe('SHOP_NOT_ALLOWED');

    const one = await login('owner.one@ecotech.test');
    const crossShop = await me(one.accessToken, SHOP_TWO);
    expect(crossShop.status).toBe(403);
    expect(code(crossShop)).toBe('SHOP_NOT_ALLOWED');
  });

  it('select-shop: a two-shop login picks shop B without x-org-id; the login is audited there', async () => {
    const empB = 'd3000000-0000-0000-0000-000000000029'; // multi.shop in dev-shop-two
    const multi = await login('multi.shop@ecotech.test');
    expect(multi.requiresShopSelection).toBe(true);
    const before = await auditCount(empB, 'auth.login');

    const res = await post('/api/auth/select-shop', { orgId: SHOP_TWO }, multi.accessToken);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    const body = AuthSelectShopResponse.parse(res.body);
    expect(body.user.email).toBe('multi.shop@ecotech.test');
    expect(body.shop).toMatchObject({
      orgId: SHOP_TWO,
      tenantSlug: 'dev-shop-two',
      role: 'ACCOUNTANT',
    });
    expect(await auditCount(empB, 'auth.login')).toBe(before + 1);

    // The same tokens then work in that shop with x-org-id.
    expect(AuthMeResponse.parse((await me(multi.accessToken, SHOP_TWO)).body).org.id).toBe(
      SHOP_TWO,
    );

    const elsewhere = await post(
      '/api/auth/select-shop',
      { orgId: 'ffffffff-ffff-4fff-8fff-ffffffffffff' },
      multi.accessToken,
    );
    expect(elsewhere.status).toBe(403);
    expect(code(elsewhere)).toBe('SHOP_NOT_ALLOWED');
  });

  it('username login with the shop slug picks that shop for a two-shop login', async () => {
    const res = await login('multi.shop', PASSWORD, 'dev-shop-two');
    expect(res.requiresShopSelection).toBe(false);
    expect(res.shops.map((s) => s.orgId)).toEqual([SHOP_TWO]);
  });

  it('refresh: the new access token works on /me; the old refresh token cannot be reused', async () => {
    const first = await login('cashier.one@ecotech.test');
    const refreshed = await post('/api/auth/refresh', { refreshToken: first.refreshToken });
    expect(refreshed.status).toBe(200);
    const next = AuthSession.parse(refreshed.body);
    expect(next.refreshToken).not.toBe(first.refreshToken);
    expect((await me(next.accessToken)).status).toBe(200);

    // GoTrue (v2.197) still accepts the direct parent of an unused refresh token and returns
    // the same active pair (a retry after a lost response). Once the new token has been used,
    // the old one is dead. Past refresh_token_reuse_interval (10 s locally) as well.
    const rotated = await post('/api/auth/refresh', { refreshToken: next.refreshToken });
    expect(rotated.status).toBe(200);
    await new Promise((r) => setTimeout(r, 11_000));
    const reused = await post('/api/auth/refresh', { refreshToken: first.refreshToken });
    expect(reused.status).toBe(401);
    expect(code(reused)).toBe('TOKEN_INVALID');
  }, 30_000);

  it('logout: the old access token gets 401 on /me and the refresh token gets 401', async () => {
    const s = await login('cashier.two@ecotech.test');
    expect((await me(s.accessToken)).status).toBe(200);

    const out = await post('/api/auth/logout', {}, s.accessToken);
    expect(out.status).toBe(200);
    expect(out.body).toEqual({ ok: true });

    const after = await me(s.accessToken);
    expect(after.status).toBe(401);
    expect(code(after)).toBe('TOKEN_INVALID');
    const refresh = await post('/api/auth/refresh', { refreshToken: s.refreshToken });
    expect(refresh.status).toBe(401);
    expect(code(refresh)).toBe('TOKEN_INVALID');
  });

  it('login and logout each write one audit row; a failed login writes a login_attempts row and no audit row', async () => {
    const emp = 'd3000000-0000-0000-0000-000000000022'; // cashier.two
    const loginsBefore = await auditCount(emp, 'auth.login');
    const logoutsBefore = await auditCount(emp, 'auth.logout');
    const s = await login('cashier.two@ecotech.test');
    expect(await auditCount(emp, 'auth.login')).toBe(loginsBefore + 1);
    await post('/api/auth/logout', {}, s.accessToken);
    expect(await auditCount(emp, 'auth.logout')).toBe(logoutsBefore + 1);

    const marker = `fail-${Date.now()}@ecotech.test`;
    const bad = await post('/api/auth/login', { identifier: marker, password: 'wrong-password' });
    expect(bad.status).toBe(401);
    expect(code(bad)).toBe('INVALID_CREDENTIALS');
    const { data, error } = await service
      .from('login_attempts')
      .select('success, ip')
      .eq('identifier', marker);
    if (error) throw new Error(error.message);
    expect(data).toHaveLength(1);
    expect(data?.[0]?.success).toBe(false);
    expect(await auditCount(emp, 'auth.login')).toBe(loginsBefore + 1);
  });

  it('the 6th attempt after 5 failures in the window is 429 TOO_MANY_LOGIN_ATTEMPTS', async () => {
    const ghost = `ghost-${Date.now()}@ecotech.test`;
    for (let i = 0; i < 5; i++) {
      const res = await post('/api/auth/login', { identifier: ghost, password: 'wrong-password' });
      expect(res.status).toBe(401);
    }
    const sixth = await post('/api/auth/login', { identifier: ghost, password: 'wrong-password' });
    expect(sixth.status).toBe(429);
    expect(code(sixth)).toBe('TOO_MANY_LOGIN_ATTEMPTS');
  });

  it('reset: forgot-password email in Mailpit -> recovery token -> /reset-password -> new password works, old fails', async () => {
    const email = 'cashier.one@ecotech.test';
    const newPassword = `Reset-${Date.now()}!`;
    await fetch(`${MAILPIT}/api/v1/messages`, { method: 'DELETE' });

    const forgot = await post('/api/auth/forgot-password', { identifier: email });
    expect(forgot.status).toBe(202);

    // The email arrives in Mailpit.
    let link: string | undefined;
    for (let i = 0; i < 20 && !link; i++) {
      await new Promise((r) => setTimeout(r, 500));
      const list = (await (
        await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`)
      ).json()) as {
        messages: { ID: string }[];
      };
      const id = list.messages[0]?.ID;
      if (!id) continue;
      const msg = (await (await fetch(`${MAILPIT}/api/v1/message/${id}`)).json()) as {
        Text: string;
      };
      link = /https?:\/\/\S+\/auth\/v1\/verify\?[^\s)]+/.exec(msg.Text)?.[0];
    }
    expect(link).toBeDefined();

    // Following the link gives the recovery session in the redirect (what the reset page reads).
    const verify = await fetch(link as string, { redirect: 'manual' });
    const location = verify.headers.get('location') ?? '';
    const token = new URLSearchParams(location.split('#')[1] ?? '').get('access_token');
    expect(token).toBeTruthy();

    const reset = await post('/api/auth/reset-password', { token, newPassword });
    expect(reset.status, JSON.stringify(reset.body)).toBe(200);

    const withNew = await login(email, newPassword);
    const withOld = await post('/api/auth/login', { identifier: email, password: PASSWORD });
    expect(withOld.status).toBe(401);

    // Put the seed password back (change-password, logged in with the new one).
    const restore = await post(
      '/api/auth/change-password',
      { currentPassword: newPassword, newPassword: PASSWORD },
      withNew.accessToken,
    );
    expect(restore.status, JSON.stringify(restore.body)).toBe(200);
    await login(email, PASSWORD);
  }, 30_000);

  it('change-password: other sessions end (old refresh token fails), this one stays, one audit row', async () => {
    const email = 'owner.two@ecotech.test';
    const emp = 'd3000000-0000-0000-0000-000000000021';
    const newPassword = `Changed-${Date.now()}!`;
    const otherDevice = await login(email);
    const thisDevice = await login(email);
    const auditsBefore = await auditCount(emp, 'auth.password_change');

    const res = await post(
      '/api/auth/change-password',
      { currentPassword: PASSWORD, newPassword },
      thisDevice.accessToken,
    );
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body).toEqual({ ok: true });

    const staleRefresh = await post('/api/auth/refresh', {
      refreshToken: otherDevice.refreshToken,
    });
    expect(staleRefresh.status).toBe(401);
    expect(code(staleRefresh)).toBe('TOKEN_INVALID');
    expect((await me(otherDevice.accessToken)).status).toBe(401);
    expect((await me(thisDevice.accessToken)).status).toBe(200);
    expect(await auditCount(emp, 'auth.password_change')).toBe(auditsBefore + 1);

    // The client logs in again with the new password; then the seed password is put back.
    const again = await login(email, newPassword);
    const restore = await post(
      '/api/auth/change-password',
      { currentPassword: newPassword, newPassword: PASSWORD },
      again.accessToken,
    );
    expect(restore.status, JSON.stringify(restore.body)).toBe(200);
  });

  it('reset-password refuses a normal login token (not from the emailed link)', async () => {
    const s = await login('owner.two@ecotech.test');
    const res = await post('/api/auth/reset-password', {
      token: s.accessToken,
      newPassword: 'Should-Not-Work-1',
    });
    expect(res.status).toBe(401);
    expect(code(res)).toBe('TOKEN_INVALID');
  });

  it('change-password with a wrong current password is 401 INVALID_CREDENTIALS and the session still works', async () => {
    const s = await login('owner.two@ecotech.test');
    const res = await post(
      '/api/auth/change-password',
      { currentPassword: 'not-the-password', newPassword: 'Another-Pass-2026' },
      s.accessToken,
    );
    expect(res.status).toBe(401);
    expect(code(res)).toBe('INVALID_CREDENTIALS');
    expect((await me(s.accessToken)).status).toBe(200);
  });
});
