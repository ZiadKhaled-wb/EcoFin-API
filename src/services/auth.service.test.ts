// Unit tests for the F04 auth service. Supabase and the service-role module are mocked.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AuthError, AuthApiError } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  AuthMeResponse,
  AuthSession,
  ErrorResponse,
} from '@ziadkhaled-wb/contracts';
import type { MembershipRow } from './auth.admin';

// ---------------------------------------------------------------- mocks
const admin = vi.hoisted(() => ({
  findLoginEmailByUsername: vi.fn(),
  loadMemberships: vi.fn(),
  countRecentFailures: vi.fn(),
  recordLoginAttempt: vi.fn(),
  clearMustChangePassword: vi.fn(),
}));
vi.mock('./auth.admin', () => admin);

type Result = { data: unknown; error: unknown };

/** One fake Supabase Auth client; every createAuthClient() call returns it (calls are counted). */
const authApi = vi.hoisted(() => ({
  signInWithPassword: vi.fn(),
  refreshSession: vi.fn(),
  getUser: vi.fn(),
  verifyOtp: vi.fn(),
  resetPasswordForEmail: vi.fn(),
  admin: { signOut: vi.fn() },
}));

/** Per-request DB clients: rpc results by name, table results by table name. */
interface FakeDb {
  rpc: Record<string, Result>;
  tables: Record<string, Result>;
  clients: {
    accessToken: string;
    orgId: string | undefined;
    rpcCalls: string[];
    filters: unknown[][];
  }[];
}
const db: FakeDb = vi.hoisted(() => ({ rpc: {}, tables: {}, clients: [] }));

const supa = vi.hoisted(() => ({
  createAuthClient: vi.fn(),
  supabaseForRequest: vi.fn(),
  updatePasswordWithToken: vi.fn(),
}));

vi.mock('../utils/supabase', () => {
  supa.createAuthClient.mockImplementation(() => ({ auth: authApi }));
  supa.supabaseForRequest.mockImplementation((accessToken: string, orgId?: string) => {
    const client = { accessToken, orgId, rpcCalls: [] as string[], filters: [] as unknown[][] };
    db.clients.push(client);
    const builder = (table: string) => {
      const b: Record<string, unknown> = {};
      for (const m of ['select', 'eq', 'order', 'in']) {
        b[m] = (...args: unknown[]) => {
          client.filters.push([table, m, ...args]);
          return b;
        };
      }
      const result = () => db.tables[table] ?? { data: null, error: null };
      b['maybeSingle'] = () => Promise.resolve(result());
      b['then'] = (resolve: (r: Result) => unknown) => Promise.resolve(result()).then(resolve);
      return b;
    };
    return {
      rpc: (name: string) => {
        client.rpcCalls.push(name);
        return Promise.resolve(db.rpc[name] ?? { data: null, error: null });
      },
      from: builder,
    };
  });
  return supa;
});

import * as auth from './auth.service';
import { AppError } from '../utils/errors';

// ---------------------------------------------------------------- fixtures
const META = { ip: '203.0.113.9', userAgent: 'vitest', requestId: 'req-1' };
const ORG_A = '11111111-1111-4111-8111-111111111111';
const ORG_B = '22222222-2222-4222-8222-222222222222';
const USER = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const EMP = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

function jwt(payload: Record<string, unknown>): string {
  const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${b64({ alg: 'HS256' })}.${b64(payload)}.sig`;
}
const ACCESS = jwt({ sub: USER, amr: [{ method: 'password' }] });
const RECOVERY = jwt({ sub: USER, amr: [{ method: 'otp' }] });

function session(token = ACCESS) {
  return {
    access_token: token,
    refresh_token: 'refresh-1',
    expires_at: 1_900_000_000,
    expires_in: 3600,
    token_type: 'bearer',
    user: { id: USER, email: 'owner.one@ecotech.test' },
  };
}

function membership(over: Partial<MembershipRow> = {}): MembershipRow {
  return {
    employeeId: EMP,
    orgId: ORG_A,
    orgName: 'Shop A',
    tenantSlug: 'shop-a',
    role: 'OWNER',
    isActive: true,
    archived: false,
    mustChangePassword: false,
    orgStatus: 'active',
    subscriptionEnd: null,
    timezone: 'Africa/Cairo',
    ...over,
  };
}

const SHOP_A = { org_id: ORG_A, org_name: 'Shop A', tenant_slug: 'shop-a', role: 'OWNER' };
const SHOP_B = { org_id: ORG_B, org_name: 'Shop B', tenant_slug: 'shop-b', role: 'ACCOUNTANT' };

function signInOk(token = ACCESS) {
  authApi.signInWithPassword.mockResolvedValue({
    data: { session: session(token), user: session(token).user },
    error: null,
  });
}
function signInWrongPassword() {
  authApi.signInWithPassword.mockResolvedValue({
    data: { session: null, user: null },
    error: new AuthApiError('Invalid login credentials', 400, 'invalid_credentials'),
  });
}

async function caught(p: Promise<unknown>): Promise<AppError> {
  try {
    await p;
  } catch (err) {
    if (err instanceof AppError) return err;
    throw err;
  }
  throw new Error('expected an AppError');
}

/** The client-visible body the error handler would send for this error. */
function body(err: AppError) {
  return ErrorResponse.parse({ error: { code: err.code, message: err.message } });
}

beforeEach(() => {
  vi.clearAllMocks();
  db.rpc = {};
  db.tables = {};
  db.clients = [];
  admin.countRecentFailures.mockResolvedValue(0);
  admin.recordLoginAttempt.mockResolvedValue(undefined);
  admin.findLoginEmailByUsername.mockResolvedValue('owner.one@ecotech.test');
  admin.loadMemberships.mockResolvedValue([membership()]);
  authApi.admin.signOut.mockResolvedValue({ data: null, error: null });
  db.rpc['my_shops'] = { data: [SHOP_A], error: null };
});

// ===========================================================================
describe('login', () => {
  it('email login: returns tokens, the single shop and no selection; never looks up a username', async () => {
    signInOk();
    const res = await auth.login({ identifier: 'Owner.One@EcoTech.test', password: 'pw' }, META);

    expect(AuthLoginResponse.parse(res)).toEqual(res);
    expect(res).toMatchObject({
      accessToken: ACCESS,
      refreshToken: 'refresh-1',
      expiresAt: new Date(1_900_000_000 * 1000).toISOString(),
      user: { id: USER, email: 'owner.one@ecotech.test' },
      requiresShopSelection: false,
      shops: [{ orgId: ORG_A, orgName: 'Shop A', tenantSlug: 'shop-a', role: 'OWNER' }],
    });
    expect(admin.findLoginEmailByUsername).not.toHaveBeenCalled();
    expect(authApi.signInWithPassword).toHaveBeenCalledWith({
      email: 'owner.one@ecotech.test',
      password: 'pw',
    });
  });

  it('username login: resolves (slug, username) to the login email, then signs in', async () => {
    signInOk();
    const res = await auth.login(
      { identifier: 'owner.one', password: 'pw', tenantSlug: 'shop-a' },
      META,
    );
    expect(admin.findLoginEmailByUsername).toHaveBeenCalledWith('shop-a', 'owner.one');
    expect(authApi.signInWithPassword).toHaveBeenCalledWith({
      email: 'owner.one@ecotech.test',
      password: 'pw',
    });
    expect(res.shops.map((s) => s.orgId)).toEqual([ORG_A]);
  });

  it('success: records the login in the active shop through auth_record_login with the user JWT', async () => {
    signInOk();
    await auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META);
    const recorder = db.clients.find((c) => c.rpcCalls.includes('auth_record_login'));
    expect(recorder).toMatchObject({ accessToken: ACCESS, orgId: ORG_A });
    expect(admin.recordLoginAttempt).toHaveBeenCalledTimes(1);
    expect(admin.recordLoginAttempt).toHaveBeenCalledWith({
      identifier: 'owner.one@ecotech.test',
      tenantSlug: null,
      success: true,
      ip: META.ip,
      userAgent: META.userAgent,
    });
  });

  it('wrong password, unknown user and unknown slug give the same 401 INVALID_CREDENTIALS body', async () => {
    signInWrongPassword();
    const wrongPassword = await caught(
      auth.login({ identifier: 'owner.one@ecotech.test', password: 'x' }, META),
    );

    admin.findLoginEmailByUsername.mockResolvedValue(null);
    const unknownUser = await caught(
      auth.login({ identifier: 'nobody', password: 'x', tenantSlug: 'shop-a' }, META),
    );
    const unknownSlug = await caught(
      auth.login({ identifier: 'owner.one', password: 'x', tenantSlug: 'no-shop' }, META),
    );

    for (const err of [wrongPassword, unknownUser, unknownSlug]) {
      expect(err.statusCode).toBe(401);
      expect(err.code).toBe('INVALID_CREDENTIALS');
    }
    expect(body(unknownUser)).toEqual(body(wrongPassword));
    expect(body(unknownSlug)).toEqual(body(wrongPassword));
    // Unknown user / slug never reach Supabase sign-in.
    expect(authApi.signInWithPassword).toHaveBeenCalledTimes(1);
    // Every attempt is recorded once, as a failure.
    expect(admin.recordLoginAttempt).toHaveBeenCalledTimes(3);
    for (const [arg] of admin.recordLoginAttempt.mock.calls)
      expect(arg).toMatchObject({ success: false });
  });

  it.each([
    ['inactive employee', membership({ isActive: false }), 'ACCOUNT_DISABLED'],
    ['archived employee', membership({ archived: true }), 'ACCOUNT_DISABLED'],
    ['suspended shop', membership({ orgStatus: 'suspended' }), 'ORG_SUSPENDED'],
    ['closed shop', membership({ orgStatus: 'closed' }), 'ORG_SUSPENDED'],
    ['shop with status expired', membership({ orgStatus: 'expired' }), 'ORG_SUSPENDED'],
  ])('%s -> 403 %s and the new session is revoked', async (_name, row, code) => {
    signInOk();
    admin.loadMemberships.mockResolvedValue([row]);
    const err = await caught(
      auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META),
    );
    expect(err.statusCode).toBe(403);
    expect(err.code).toBe(code);
    expect(authApi.admin.signOut).toHaveBeenCalledWith(ACCESS, 'local');
    expect(db.clients.some((c) => c.rpcCalls.includes('auth_record_login'))).toBe(false);
    expect(admin.recordLoginAttempt).toHaveBeenCalledTimes(1);
    expect(admin.recordLoginAttempt.mock.calls[0]?.[0]).toMatchObject({ success: false });
  });

  it('a subscription ending today (shop timezone) is still valid', async () => {
    signInOk();
    admin.loadMemberships.mockResolvedValue([
      membership({ subscriptionEnd: auth.todayIn('Africa/Cairo') }),
    ]);
    const res = await auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META);
    expect(res.shops).toHaveLength(1);
  });
  it('an expired subscription still permits login and is audited', async () => {
    signInOk();
    admin.loadMemberships.mockResolvedValue([membership({ subscriptionEnd: '2000-01-01' })]);
    const res = await auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META);
    expect(res.shops).toHaveLength(1);
    expect(db.clients.some((c) => c.rpcCalls.includes('auth_record_login'))).toBe(true);
    expect(authApi.admin.signOut).not.toHaveBeenCalled();
  });

  it('multi-shop login: requiresShopSelection with both shops, and no login audit yet', async () => {
    signInOk();
    admin.loadMemberships.mockResolvedValue([
      membership(),
      membership({
        employeeId: 'e2',
        orgId: ORG_B,
        orgName: 'Shop B',
        tenantSlug: 'shop-b',
        role: 'ACCOUNTANT',
      }),
    ]);
    db.rpc['my_shops'] = { data: [SHOP_A, SHOP_B], error: null };
    const res = await auth.login({ identifier: 'multi@ecotech.test', password: 'pw' }, META);
    expect(res.requiresShopSelection).toBe(true);
    expect(res.shops.map((s) => [s.orgId, s.role])).toEqual([
      [ORG_A, 'OWNER'],
      [ORG_B, 'ACCOUNTANT'],
    ]);
    expect(db.clients.some((c) => c.rpcCalls.includes('auth_record_login'))).toBe(false);
  });

  it('multi-shop login with a tenant slug picks that shop: one shop, no selection, audit there', async () => {
    signInOk();
    admin.loadMemberships.mockResolvedValue([
      membership(),
      membership({
        employeeId: 'e2',
        orgId: ORG_B,
        orgName: 'Shop B',
        tenantSlug: 'shop-b',
        role: 'ACCOUNTANT',
      }),
    ]);
    db.rpc['my_shops'] = { data: [SHOP_A, SHOP_B], error: null };
    const res = await auth.login(
      { identifier: 'multi', password: 'pw', tenantSlug: 'shop-b' },
      META,
    );
    expect(res.requiresShopSelection).toBe(false);
    expect(res.shops.map((s) => s.orgId)).toEqual([ORG_B]);
    expect(db.clients.find((c) => c.rpcCalls.includes('auth_record_login'))?.orgId).toBe(ORG_B);
  });

  it('a usable shop next to a suspended one: login works with only the usable shop', async () => {
    signInOk();
    admin.loadMemberships.mockResolvedValue([
      membership(),
      membership({ employeeId: 'e2', orgId: ORG_B, tenantSlug: 'shop-b', orgStatus: 'suspended' }),
    ]);
    db.rpc['my_shops'] = { data: [SHOP_A], error: null };
    const res = await auth.login({ identifier: 'multi@ecotech.test', password: 'pw' }, META);
    expect(res.requiresShopSelection).toBe(false);
    expect(res.shops.map((s) => s.orgId)).toEqual([ORG_A]);
  });

  it('mustChangePassword comes from the employee row', async () => {
    signInOk();
    admin.loadMemberships.mockResolvedValue([membership({ mustChangePassword: true })]);
    const res = await auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META);
    expect(res.mustChangePassword).toBe(true);
  });

  it('email + a slug the login does not belong to -> INVALID_CREDENTIALS and the session is revoked', async () => {
    signInOk();
    const err = await caught(
      auth.login(
        { identifier: 'owner.one@ecotech.test', password: 'pw', tenantSlug: 'shop-b' },
        META,
      ),
    );
    expect(err.code).toBe('INVALID_CREDENTIALS');
    expect(authApi.admin.signOut).toHaveBeenCalledWith(ACCESS, 'local');
    expect(admin.recordLoginAttempt).toHaveBeenCalledTimes(1);
  });

  it('a database refusal from auth_record_login is mapped and revokes the session', async () => {
    signInOk();
    db.rpc['auth_record_login'] = {
      data: null,
      error: { message: 'ORG_SUSPENDED', code: '42501' },
    };
    const err = await caught(
      auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META),
    );
    expect(err.code).toBe('ORG_SUSPENDED');
    expect(authApi.admin.signOut).toHaveBeenCalledWith(ACCESS, 'local');
  });

  describe('D17 lockout', () => {
    it('the 6th attempt after 5 failures -> 429 TOO_MANY_LOGIN_ATTEMPTS without calling Supabase sign-in', async () => {
      admin.countRecentFailures.mockResolvedValue(5);
      const err = await caught(
        auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META),
      );
      expect(err.statusCode).toBe(429);
      expect(err.code).toBe('TOO_MANY_LOGIN_ATTEMPTS');
      expect(authApi.signInWithPassword).not.toHaveBeenCalled();
      expect(admin.findLoginEmailByUsername).not.toHaveBeenCalled();
      expect(admin.recordLoginAttempt).toHaveBeenCalledTimes(1);
      expect(admin.recordLoginAttempt.mock.calls[0]?.[0]).toMatchObject({ success: false });
    });

    it('4 failures still allow an attempt', async () => {
      admin.countRecentFailures.mockResolvedValue(4);
      signInOk();
      await auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META);
      expect(authApi.signInWithPassword).toHaveBeenCalledTimes(1);
    });

    it('counts usernames per shop and emails across shops, inside the configured window', async () => {
      signInOk();
      await auth.login({ identifier: 'owner.one', password: 'pw', tenantSlug: 'shop-a' }, META);
      expect(admin.countRecentFailures).toHaveBeenLastCalledWith('owner.one', 'shop-a', 15);
      await auth.login(
        { identifier: 'owner.one@ecotech.test', password: 'pw', tenantSlug: 'shop-a' },
        META,
      );
      expect(admin.countRecentFailures).toHaveBeenLastCalledWith(
        'owner.one@ecotech.test',
        null,
        15,
      );
    });
  });

  it('Supabase Auth rate-limiting the sign-in -> 429 TOO_MANY_REQUESTS, not a wrong password', async () => {
    authApi.signInWithPassword.mockResolvedValue({
      data: { session: null, user: null },
      error: new AuthApiError('rate limited', 429, 'over_request_rate_limit'),
    });
    const err = await caught(
      auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META),
    );
    expect(err.statusCode).toBe(429);
    expect(err.code).toBe('TOO_MANY_REQUESTS');
    expect(admin.recordLoginAttempt).not.toHaveBeenCalled();
  });

  it('Supabase Auth unreachable -> 500 INTERNAL, nothing counted as a wrong password', async () => {
    authApi.signInWithPassword.mockResolvedValue({
      data: { session: null, user: null },
      error: new AuthError('fetch failed'),
    });
    const err = await caught(
      auth.login({ identifier: 'owner.one@ecotech.test', password: 'pw' }, META),
    );
    expect(err.statusCode).toBe(500);
    expect(admin.recordLoginAttempt).not.toHaveBeenCalled();
  });

  describe('super admin (no employee rows)', () => {
    beforeEach(() => {
      signInOk();
      admin.loadMemberships.mockResolvedValue([]);
    });

    it('an active super admin logs in with no shops', async () => {
      db.tables['super_admins'] = { data: { is_active: true }, error: null };
      const res = await auth.login({ identifier: 'superadmin@ecotech.test', password: 'pw' }, META);
      expect(res).toMatchObject({
        shops: [],
        requiresShopSelection: false,
        mustChangePassword: false,
      });
    });

    it('an inactive super admin -> ACCOUNT_DISABLED, session revoked', async () => {
      db.tables['super_admins'] = { data: { is_active: false }, error: null };
      const err = await caught(
        auth.login({ identifier: 'superadmin@ecotech.test', password: 'pw' }, META),
      );
      expect(err.code).toBe('ACCOUNT_DISABLED');
      expect(authApi.admin.signOut).toHaveBeenCalledWith(ACCESS, 'local');
    });

    it('a login that is neither employee nor super admin -> INVALID_CREDENTIALS, session revoked', async () => {
      db.tables['super_admins'] = { data: null, error: null };
      const err = await caught(
        auth.login({ identifier: 'stray@ecotech.test', password: 'pw' }, META),
      );
      expect(err.code).toBe('INVALID_CREDENTIALS');
      expect(authApi.admin.signOut).toHaveBeenCalledWith(ACCESS, 'local');
    });
  });
});

// ===========================================================================
describe('selectShop', () => {
  const AUTH = { userId: USER, email: 'multi@ecotech.test', accessToken: ACCESS };

  it('a shop the login belongs to: records the login there and returns it', async () => {
    db.rpc['my_shops'] = { data: [SHOP_A, SHOP_B], error: null };
    const res = await auth.selectShop(AUTH, ORG_B, META);
    expect(res.shop).toMatchObject({ orgId: ORG_B, role: 'ACCOUNTANT' });
    expect(db.clients.find((c) => c.rpcCalls.includes('auth_record_login'))?.orgId).toBe(ORG_B);
  });

  it('a shop the login does not belong to -> 403 SHOP_NOT_ALLOWED, nothing recorded', async () => {
    const err = await caught(auth.selectShop(AUTH, ORG_B, META));
    expect(err.code).toBe('SHOP_NOT_ALLOWED');
    expect(db.clients.some((c) => c.rpcCalls.includes('auth_record_login'))).toBe(false);
  });
});

// ===========================================================================
describe('refresh', () => {
  it('returns the new token pair', async () => {
    authApi.refreshSession.mockResolvedValue({
      data: { session: session(), user: null },
      error: null,
    });
    const res = await auth.refresh('refresh-0');
    expect(AuthSession.parse(res)).toEqual(res);
    expect(authApi.refreshSession).toHaveBeenCalledWith({ refresh_token: 'refresh-0' });
  });

  it.each([429, 500, 503])(
    'Supabase Auth answering %s on refresh -> 500 INTERNAL (the client keeps its session)',
    async (status) => {
      authApi.refreshSession.mockResolvedValue({
        data: { session: null, user: null },
        error: new AuthApiError('upstream trouble', status, undefined),
      });
      const err = await caught(auth.refresh('refresh-0'));
      expect(err.statusCode).toBe(500);
      expect(err.code).toBe('INTERNAL');
    },
  );

  it('an invalid or already-used refresh token -> 401 TOKEN_INVALID', async () => {
    authApi.refreshSession.mockResolvedValue({
      data: { session: null, user: null },
      error: new AuthApiError(
        'Invalid Refresh Token: Refresh Token Not Found',
        400,
        'refresh_token_not_found',
      ),
    });
    const err = await caught(auth.refresh('used'));
    expect(err.statusCode).toBe(401);
    expect(err.code).toBe('TOKEN_INVALID');
  });
});

// ===========================================================================
describe('logout', () => {
  const AUTH = { userId: USER, email: 'owner.one@ecotech.test', accessToken: ACCESS, orgId: ORG_A };

  it('writes the logout audit with the user JWT, then revokes this session (scope local)', async () => {
    await auth.logout(AUTH, META);
    expect(db.clients[0]).toMatchObject({
      accessToken: ACCESS,
      orgId: ORG_A,
      rpcCalls: ['auth_record_logout'],
    });
    expect(authApi.admin.signOut).toHaveBeenCalledWith(ACCESS, 'local');
  });

  it('still revokes when there is no shop session to audit (multi-shop before selection)', async () => {
    db.rpc['auth_record_logout'] = { data: null, error: { message: 'SHOP_SELECTION_REQUIRED' } };
    await auth.logout({ ...AUTH, orgId: undefined }, META);
    expect(authApi.admin.signOut).toHaveBeenCalledWith(ACCESS, 'local');
  });

  it('a failed revocation is an error (500), never a silent success', async () => {
    authApi.admin.signOut.mockResolvedValue({
      data: null,
      error: new AuthApiError('boom', 500, undefined),
    });
    const err = await caught(auth.logout(AUTH, META));
    expect(err.statusCode).toBe(500);
  });
});

// ===========================================================================
describe('forgotPassword', () => {
  beforeEach(() => authApi.resetPasswordForEmail.mockResolvedValue({ data: {}, error: null }));

  it('known email: sends the recovery email with redirectTo = FRONTEND_URL/reset-password', async () => {
    await auth.forgotPassword({ identifier: 'owner.one@ecotech.test' });
    expect(authApi.resetPasswordForEmail).toHaveBeenCalledWith('owner.one@ecotech.test', {
      redirectTo: `${process.env['FRONTEND_URL']}/reset-password`,
    });
  });

  it('username + slug: resolves the email first', async () => {
    await auth.forgotPassword({ identifier: 'owner.one', tenantSlug: 'shop-a' });
    expect(admin.findLoginEmailByUsername).toHaveBeenCalledWith('shop-a', 'owner.one');
    expect(authApi.resetPasswordForEmail).toHaveBeenCalledTimes(1);
  });

  it('unknown username: returns normally and sends nothing', async () => {
    admin.findLoginEmailByUsername.mockResolvedValue(null);
    await expect(
      auth.forgotPassword({ identifier: 'nobody', tenantSlug: 'shop-a' }),
    ).resolves.toBeUndefined();
    expect(authApi.resetPasswordForEmail).not.toHaveBeenCalled();
  });

  it('never throws, even when the lookup or Supabase fails', async () => {
    admin.findLoginEmailByUsername.mockRejectedValue(new Error('db down'));
    await expect(
      auth.forgotPassword({ identifier: 'x.y', tenantSlug: 'shop-a' }),
    ).resolves.toBeUndefined();
    authApi.resetPasswordForEmail.mockResolvedValue({
      data: null,
      error: new AuthApiError('rate', 429, undefined),
    });
    await expect(auth.forgotPassword({ identifier: 'a@b.co' })).resolves.toBeUndefined();
  });
});

// ===========================================================================
describe('resetPassword', () => {
  beforeEach(() => {
    authApi.getUser.mockResolvedValue({ data: { user: { id: USER } }, error: null });
    supa.updatePasswordWithToken.mockResolvedValue({ ok: true, status: 200 });
  });

  it('recovery access token: validated by Supabase, password set for that user, every session revoked', async () => {
    await auth.resetPassword({ token: RECOVERY, newPassword: 'NewPass-2026!' });
    expect(authApi.getUser).toHaveBeenCalledWith(RECOVERY);
    expect(supa.updatePasswordWithToken).toHaveBeenCalledWith(RECOVERY, 'NewPass-2026!');
    expect(authApi.admin.signOut).toHaveBeenCalledWith(RECOVERY, 'global');
  });

  it('a token_hash from the link is exchanged with verifyOtp(type recovery) first', async () => {
    authApi.verifyOtp.mockResolvedValue({
      data: { session: session(RECOVERY), user: null },
      error: null,
    });
    await auth.resetPassword({
      token: '77e732fb462b52810fa986ccdb45514b24e5dd202740bca4b99c3ab1',
      newPassword: 'NewPass-2026!',
    });
    expect(authApi.verifyOtp).toHaveBeenCalledWith({
      token_hash: '77e732fb462b52810fa986ccdb45514b24e5dd202740bca4b99c3ab1',
      type: 'recovery',
    });
    expect(supa.updatePasswordWithToken).toHaveBeenCalledWith(RECOVERY, 'NewPass-2026!');
  });

  it('a normal (password-login) access token is refused: 401 TOKEN_INVALID, nothing changed', async () => {
    const err = await caught(auth.resetPassword({ token: ACCESS, newPassword: 'NewPass-2026!' }));
    expect(err.code).toBe('TOKEN_INVALID');
    expect(supa.updatePasswordWithToken).not.toHaveBeenCalled();
  });

  it('a token Supabase rejects (expired, revoked, forged) -> 401 TOKEN_INVALID', async () => {
    authApi.getUser.mockResolvedValue({
      data: { user: null },
      error: new AuthApiError('bad', 403, 'session_not_found'),
    });
    const err = await caught(auth.resetPassword({ token: RECOVERY, newPassword: 'NewPass-2026!' }));
    expect(err.code).toBe('TOKEN_INVALID');
    expect(supa.updatePasswordWithToken).not.toHaveBeenCalled();
  });

  it('Supabase Auth failing (503) while checking the recovery token -> 500, not TOKEN_INVALID', async () => {
    authApi.getUser.mockResolvedValue({
      data: { user: null },
      error: new AuthApiError('unavailable', 503, undefined),
    });
    const err = await caught(auth.resetPassword({ token: RECOVERY, newPassword: 'NewPass-2026!' }));
    expect(err.statusCode).toBe(500);
    expect(supa.updatePasswordWithToken).not.toHaveBeenCalled();
  });

  it('an invalid token_hash -> 401 TOKEN_INVALID', async () => {
    authApi.verifyOtp.mockResolvedValue({
      data: { session: null, user: null },
      error: new AuthApiError('expired', 403, 'otp_expired'),
    });
    const err = await caught(
      auth.resetPassword({ token: 'deadbeef', newPassword: 'NewPass-2026!' }),
    );
    expect(err.code).toBe('TOKEN_INVALID');
  });

  it('a password Supabase rejects (same or weak) -> 400 VALIDATION_FAILED', async () => {
    supa.updatePasswordWithToken.mockResolvedValue({
      ok: false,
      status: 422,
      code: 'same_password',
    });
    const err = await caught(auth.resetPassword({ token: RECOVERY, newPassword: 'NewPass-2026!' }));
    expect(err.code).toBe('VALIDATION_FAILED');
    expect(authApi.admin.signOut).not.toHaveBeenCalled();
  });
});

// ===========================================================================
describe('changePassword', () => {
  const AUTH = { userId: USER, email: 'owner.one@ecotech.test', accessToken: ACCESS };
  const BODY = { currentPassword: 'Old-Pass-2026!', newPassword: 'New-Pass-2026!' };
  const CHECK = jwt({ sub: USER, amr: [{ method: 'password' }], n: 2 });

  beforeEach(() => {
    signInOk(CHECK);
    supa.updatePasswordWithToken.mockResolvedValue({ ok: true, status: 200 });
  });

  it('verifies the current password, updates it with the caller token, ends the other sessions, audits, clears the flag', async () => {
    await auth.changePassword(AUTH, BODY, META);
    expect(authApi.signInWithPassword).toHaveBeenCalledWith({
      email: 'owner.one@ecotech.test',
      password: 'Old-Pass-2026!',
    });
    expect(authApi.admin.signOut).toHaveBeenCalledWith(CHECK, 'local');
    expect(supa.updatePasswordWithToken).toHaveBeenCalledWith(ACCESS, 'New-Pass-2026!');
    expect(authApi.admin.signOut).toHaveBeenCalledWith(ACCESS, 'others');
    expect(
      db.clients.find((c) => c.rpcCalls.includes('auth_record_password_change')),
    ).toMatchObject({ accessToken: ACCESS, orgId: ORG_A });
    // D24: the flag is cleared through the service-role module, with the verified user id.
    expect(admin.clearMustChangePassword).toHaveBeenCalledWith(USER);
  });

  it('the flag is cleared only after Supabase Auth accepted the new password', async () => {
    supa.updatePasswordWithToken.mockResolvedValue({
      ok: false,
      status: 422,
      code: 'weak_password',
    });
    const err = await caught(auth.changePassword(AUTH, BODY, META));
    expect(err.code).toBe('VALIDATION_FAILED');
    expect(admin.clearMustChangePassword).not.toHaveBeenCalled();
    expect(authApi.admin.signOut).not.toHaveBeenCalledWith(ACCESS, 'others');
    expect(db.clients.some((c) => c.rpcCalls.includes('auth_record_password_change'))).toBe(false);
  });

  it('a failed audit write leaves the flag set (safe direction) and reports an error', async () => {
    db.rpc['auth_record_password_change'] = { data: null, error: { message: 'boom' } };
    const err = await caught(auth.changePassword(AUTH, BODY, META));
    expect(err.statusCode).toBe(500);
    expect(admin.clearMustChangePassword).not.toHaveBeenCalled();
    // The other sessions are still ended: the password did change.
    expect(authApi.admin.signOut).toHaveBeenCalledWith(ACCESS, 'others');
  });

  it('wrong current password -> 401 INVALID_CREDENTIALS (not a token code), recorded, nothing changed', async () => {
    signInWrongPassword();
    const err = await caught(auth.changePassword(AUTH, BODY, META));
    expect(err.statusCode).toBe(401);
    expect(err.code).toBe('INVALID_CREDENTIALS');
    expect(admin.recordLoginAttempt).toHaveBeenCalledWith(
      expect.objectContaining({ success: false }),
    );
    expect(supa.updatePasswordWithToken).not.toHaveBeenCalled();
    expect(admin.clearMustChangePassword).not.toHaveBeenCalled();
  });

  it('locked out -> 429 without checking the password', async () => {
    admin.countRecentFailures.mockResolvedValue(5);
    const err = await caught(auth.changePassword(AUTH, BODY, META));
    expect(err.code).toBe('TOO_MANY_LOGIN_ATTEMPTS');
    expect(authApi.signInWithPassword).not.toHaveBeenCalled();
  });

  it('new password equal to the current one -> 400 VALIDATION_FAILED', async () => {
    const err = await caught(
      auth.changePassword(AUTH, { currentPassword: 'Same-2026!', newPassword: 'Same-2026!' }, META),
    );
    expect(err.code).toBe('VALIDATION_FAILED');
  });

  it('multi-shop without x-org-id -> SHOP_SELECTION_REQUIRED before anything changes', async () => {
    db.rpc['my_shops'] = { data: [SHOP_A, SHOP_B], error: null };
    const err = await caught(auth.changePassword(AUTH, BODY, META));
    expect(err.code).toBe('SHOP_SELECTION_REQUIRED');
    expect(authApi.signInWithPassword).not.toHaveBeenCalled();
  });
});

// ===========================================================================
describe('getMe', () => {
  const AUTH = { userId: USER, email: 'owner.one@ecotech.test', accessToken: ACCESS };

  beforeEach(() => {
    db.tables['employees'] = {
      data: {
        id: EMP,
        full_name: 'Owner One',
        email: 'owner.one@ecotech.test',
        username: 'owner.one',
        role: 'OWNER',
        default_branch_id: null,
        must_change_password: false,
      },
      error: null,
    };
    db.tables['organizations'] = {
      data: {
        id: ORG_A,
        tenant_slug: 'shop-a',
        name: 'Shop A',
        timezone: 'Africa/Cairo',
        default_language: 'ar',
        status: 'active',
        plan_key: 'retail',
        subscription_end: '2027-01-01',
      },
      error: null,
    };
    db.tables['branches'] = {
      data: [
        { id: '33333333-3333-4333-8333-333333333333', code: 'BR1', name: 'Main', is_main: true },
      ],
      error: null,
    };
  });

  it('single shop, no header: reads as the caller in that shop and returns the contract shape', async () => {
    const res = await auth.getMe(AUTH, META);
    expect(AuthMeResponse.parse(res)).toEqual(res);
    expect(res.employee.fullName).toBe('Owner One');
    expect(res.branches).toEqual([
      { id: '33333333-3333-4333-8333-333333333333', code: 'BR1', name: 'Main', isMain: true },
    ]);
    const reader = db.clients.find((c) => c.filters.some((f) => f[0] === 'employees'));
    expect(reader).toMatchObject({ accessToken: ACCESS, orgId: ORG_A });
    expect(reader?.filters).toContainEqual(['employees', 'eq', 'auth_user_id', USER]);
  });

  it('two shops and no x-org-id -> 400 SHOP_SELECTION_REQUIRED', async () => {
    db.rpc['my_shops'] = { data: [SHOP_A, SHOP_B], error: null };
    const err = await caught(auth.getMe(AUTH, META));
    expect(err.statusCode).toBe(400);
    expect(err.code).toBe('SHOP_SELECTION_REQUIRED');
  });

  it('x-org-id of shop B: the request runs in shop B', async () => {
    db.rpc['my_shops'] = { data: [SHOP_A, SHOP_B], error: null };
    await auth.getMe({ ...AUTH, orgId: ORG_B }, META);
    expect(db.clients.find((c) => c.filters.some((f) => f[0] === 'employees'))?.orgId).toBe(ORG_B);
  });

  it('x-org-id of a shop the caller is not in -> 403 SHOP_NOT_ALLOWED, no data read', async () => {
    const err = await caught(auth.getMe({ ...AUTH, orgId: ORG_B }, META));
    expect(err.statusCode).toBe(403);
    expect(err.code).toBe('SHOP_NOT_ALLOWED');
    expect(db.clients.some((c) => c.filters.length > 0)).toBe(false);
  });

  it('no usable shop -> 403 NOT_AN_EMPLOYEE', async () => {
    db.rpc['my_shops'] = { data: [], error: null };
    const err = await caught(auth.getMe(AUTH, META));
    expect(err.code).toBe('NOT_AN_EMPLOYEE');
  });
});
