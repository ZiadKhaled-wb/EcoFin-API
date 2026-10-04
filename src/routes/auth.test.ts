// HTTP-level checks of /api/auth/* through the real app (validation, status codes, error shape).
// Supabase and the service-role module are mocked.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import request from 'supertest';
import { AuthApiError } from '@supabase/supabase-js';
import { Ack, AuthSelectShopResponse, ErrorResponse } from '@ziadkhaled-wb/contracts';

const admin = vi.hoisted(() => ({
  findLoginEmailByUsername: vi.fn(),
  loadMemberships: vi.fn(),
  countRecentFailures: vi.fn(),
  recordLoginAttempt: vi.fn(),
}));
vi.mock('../services/auth.admin', () => admin);

const authApi = vi.hoisted(() => ({
  signInWithPassword: vi.fn(),
  getUser: vi.fn(),
  resetPasswordForEmail: vi.fn(),
  admin: { signOut: vi.fn() },
}));
/** rpc results by function name; every per-request client is recorded with its headers. */
interface FakeRpc {
  results: Record<string, { data: unknown; error: unknown }>;
  calls: { name: string; token: string; orgId: string | undefined }[];
}
const rpc: FakeRpc = vi.hoisted(() => ({ results: {}, calls: [] }));
vi.mock('../utils/supabase', () => ({
  createAuthClient: () => ({ auth: authApi }),
  supabaseForRequest: (token: string, orgId?: string) => ({
    rpc: (name: string) => {
      rpc.calls.push({ name, token, orgId });
      const result = Promise.resolve(rpc.results[name] ?? { data: [], error: null });
      // .single() (session_context): the queued result already holds the one row.
      return Object.assign(result, { single: () => result });
    },
  }),
  updatePasswordWithToken: vi.fn(),
  supabaseAdmin: {},
}));

import { createApp } from '../app';

const app = createApp({
  env: { TRUST_PROXY: 1, CORS_ALLOWED_ORIGINS: ['https://app.example.com'] },
});

function expectError(res: request.Response, status: number, code: string) {
  expect(res.status).toBe(status);
  const parsed = ErrorResponse.parse(res.body);
  expect(parsed.error.code).toBe(code);
  expect(parsed.error.requestId).toBeTruthy();
  return parsed;
}

beforeEach(() => {
  vi.clearAllMocks();
  rpc.results = {};
  rpc.calls = [];
  admin.countRecentFailures.mockResolvedValue(0);
  admin.recordLoginAttempt.mockResolvedValue(undefined);
  authApi.resetPasswordForEmail.mockResolvedValue({ data: {}, error: null });
});

describe('POST /api/auth/forgot-password', () => {
  it('202 { ok: true } for a known email', async () => {
    const res = await request(app)
      .post('/api/auth/forgot-password')
      .send({ identifier: 'owner.one@ecotech.test' });
    expect(res.status).toBe(202);
    expect(Ack.parse(res.body)).toEqual({ ok: true });
    expect(authApi.resetPasswordForEmail).toHaveBeenCalledTimes(1);
  });

  it('the same 202 { ok: true } for an unknown username', async () => {
    admin.findLoginEmailByUsername.mockResolvedValue(null);
    const res = await request(app)
      .post('/api/auth/forgot-password')
      .send({ identifier: 'nobody', tenantSlug: 'dev-shop-one' });
    expect(res.status).toBe(202);
    expect(res.body).toEqual({ ok: true });
    expect(authApi.resetPasswordForEmail).not.toHaveBeenCalled();
  });
});

describe('POST /api/auth/login', () => {
  it('a wrong password is 401 INVALID_CREDENTIALS in the contract error shape', async () => {
    authApi.signInWithPassword.mockResolvedValue({
      data: { session: null, user: null },
      error: new AuthApiError('Invalid login credentials', 400, 'invalid_credentials'),
    });
    const res = await request(app)
      .post('/api/auth/login')
      .send({ identifier: 'owner.one@ecotech.test', password: 'wrong' });
    const err = expectError(res, 401, 'INVALID_CREDENTIALS');
    expect(JSON.stringify(err)).not.toContain('Invalid login credentials');
  });

  it('a username without tenantSlug is a 400 VALIDATION_FAILED (contract), Supabase not called', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({ identifier: 'owner.one', password: 'x' });
    expectError(res, 400, 'VALIDATION_FAILED');
    expect(authApi.signInWithPassword).not.toHaveBeenCalled();
  });

  it('unknown body fields are rejected (strict contract)', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .send({ identifier: 'a@b.co', password: 'x', organization_id: 'x' });
    expectError(res, 400, 'VALIDATION_FAILED');
  });

  it('the lockout answers 429 TOO_MANY_LOGIN_ATTEMPTS', async () => {
    admin.countRecentFailures.mockResolvedValue(5);
    const res = await request(app)
      .post('/api/auth/login')
      .send({ identifier: 'a@b.co', password: 'x' });
    expectError(res, 429, 'TOO_MANY_LOGIN_ATTEMPTS');
  });
});

describe('POST /api/auth/refresh and /reset-password', () => {
  it('refresh validates its body', async () => {
    expectError(await request(app).post('/api/auth/refresh').send({}), 400, 'VALIDATION_FAILED');
  });

  it('reset-password rejects a short password before calling Supabase', async () => {
    const res = await request(app)
      .post('/api/auth/reset-password')
      .send({ token: 'abc', newPassword: 'short' });
    expectError(res, 400, 'VALIDATION_FAILED');
    expect(authApi.getUser).not.toHaveBeenCalled();
  });
});

describe('authenticated routes need a valid token', () => {
  it.each([
    ['get', '/api/auth/me'],
    ['post', '/api/auth/logout'],
    ['post', '/api/auth/change-password'],
  ] as const)('%s %s without a token -> 401 UNAUTHORIZED', async (method, path) => {
    expectError(await request(app)[method](path), 401, 'UNAUTHORIZED');
  });

  it('a revoked token -> 401 TOKEN_INVALID on /me', async () => {
    authApi.getUser.mockResolvedValue({
      data: { user: null },
      error: new AuthApiError(
        'Session from session_id claim in JWT does not exist',
        403,
        'session_not_found',
      ),
    });
    const res = await request(app).get('/api/auth/me').set('Authorization', 'Bearer a.b.c');
    expectError(res, 401, 'TOKEN_INVALID');
  });

  it('a malformed x-org-id -> 400 VALIDATION_FAILED', async () => {
    authApi.getUser.mockResolvedValue({
      data: { user: { id: 'u1', email: 'a@b.co' } },
      error: null,
    });
    const res = await request(app)
      .get('/api/auth/me')
      .set('Authorization', 'Bearer a.b.c')
      .set('x-org-id', 'not-a-uuid');
    expectError(res, 400, 'VALIDATION_FAILED');
  });
});

describe('POST /api/auth/select-shop', () => {
  const USER = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const ORG_A = '11111111-1111-4111-8111-111111111111';
  const ORG_B = '22222222-2222-4222-8222-222222222222';

  beforeEach(() => {
    authApi.getUser.mockResolvedValue({
      data: { user: { id: USER, email: 'multi@x.test' } },
      error: null,
    });
    rpc.results['my_shops'] = {
      data: [
        { org_id: ORG_A, org_name: 'Shop A', tenant_slug: 'shop-a', role: 'CASHIER' },
        { org_id: ORG_B, org_name: 'Shop B', tenant_slug: 'shop-b', role: 'ACCOUNTANT' },
      ],
      error: null,
    };
  });

  it('a multi-shop token with no x-org-id picks a shop: 200 { user, shop }, login audited in that shop', async () => {
    const res = await request(app)
      .post('/api/auth/select-shop')
      .set('Authorization', 'Bearer a.b.c')
      .send({ orgId: ORG_B });
    expect(res.status).toBe(200);
    expect(AuthSelectShopResponse.parse(res.body)).toEqual({
      user: { id: USER, email: 'multi@x.test' },
      shop: { orgId: ORG_B, orgName: 'Shop B', tenantSlug: 'shop-b', role: 'ACCOUNTANT' },
    });
    expect(rpc.calls).toContainEqual({ name: 'my_shops', token: 'a.b.c', orgId: undefined });
    expect(rpc.calls).toContainEqual({ name: 'auth_record_login', token: 'a.b.c', orgId: ORG_B });
  });

  it('a shop the login is not in -> 403 SHOP_NOT_ALLOWED, nothing audited', async () => {
    const res = await request(app)
      .post('/api/auth/select-shop')
      .set('Authorization', 'Bearer a.b.c')
      .send({ orgId: 'ffffffff-ffff-4fff-8fff-ffffffffffff' });
    expectError(res, 403, 'SHOP_NOT_ALLOWED');
    expect(rpc.calls.some((c) => c.name === 'auth_record_login')).toBe(false);
  });

  it('a body that is not { orgId: uuid } -> 400 VALIDATION_FAILED', async () => {
    for (const body of [{}, { orgId: 'x' }, { orgId: ORG_A, extra: 1 }]) {
      const res = await request(app)
        .post('/api/auth/select-shop')
        .set('Authorization', 'Bearer a.b.c')
        .send(body);
      expectError(res, 400, 'VALIDATION_FAILED');
    }
  });

  it('no token -> 401 UNAUTHORIZED', async () => {
    expectError(
      await request(app).post('/api/auth/select-shop').send({ orgId: ORG_A }),
      401,
      'UNAUTHORIZED',
    );
  });
});

describe('F05 status gate (session_context) on the auth routes', () => {
  const USER = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const refusal = (code: string) => ({
    data: {
      employee_id: null,
      organization_id: null,
      role: null,
      default_branch_id: null,
      branch_ids: null,
      must_change_password: null,
      refusal: code,
    },
    error: null,
  });

  beforeEach(() => {
    authApi.getUser.mockResolvedValue({
      data: { user: { id: USER, email: 'u@x.test' } },
      error: null,
    });
  });

  it.each([
    ['get', '/api/auth/me', {}],
    [
      'post',
      '/api/auth/change-password',
      { currentPassword: 'Old-pass-123!', newPassword: 'New-pass-456!' },
    ],
  ] as const)(
    '%s %s: a refused context (shop inactive) -> 403 SHOP_INACTIVE before the handler',
    async (method, path, body) => {
      rpc.results['session_context'] = refusal('SHOP_INACTIVE');
      const res = await request(app)[method](path).set('Authorization', 'Bearer a.b.c').send(body);
      expectError(res, 403, 'SHOP_INACTIVE');
      expect(rpc.calls.map((c) => c.name)).toEqual(['session_context']);
    },
  );

  it('the gate runs with the caller token and its x-org-id', async () => {
    const ORG = '11111111-1111-4111-8111-111111111111';
    rpc.results['session_context'] = refusal('SHOP_NOT_ALLOWED');
    const res = await request(app)
      .get('/api/auth/me')
      .set('Authorization', 'Bearer a.b.c')
      .set('x-org-id', ORG);
    expectError(res, 403, 'SHOP_NOT_ALLOWED');
    expect(rpc.calls).toEqual([{ name: 'session_context', token: 'a.b.c', orgId: ORG }]);
  });

  it('logout skips the gate: a user of an inactive shop can still log out', async () => {
    rpc.results['session_context'] = refusal('SHOP_INACTIVE');
    authApi.admin.signOut.mockResolvedValue({ data: null, error: null });
    const res = await request(app).post('/api/auth/logout').set('Authorization', 'Bearer a.b.c');
    expect(res.status).toBe(200);
    expect(Ack.parse(res.body)).toEqual({ ok: true });
    expect(rpc.calls.some((c) => c.name === 'session_context')).toBe(false);
  });

  it('select-shop skips the gate (it picks the shop itself)', async () => {
    rpc.results['session_context'] = refusal('SHOP_SELECTION_REQUIRED');
    await request(app)
      .post('/api/auth/select-shop')
      .set('Authorization', 'Bearer a.b.c')
      .send({ orgId: '11111111-1111-4111-8111-111111111111' });
    expect(rpc.calls.some((c) => c.name === 'session_context')).toBe(false);
  });
});

describe('per-route limiters (D24)', () => {
  it('/refresh: 60 per minute per IP, then the contract 429; it does not use the login budget', async () => {
    const ip = '198.18.0.1';
    for (let i = 0; i < 60; i++) {
      const res = await request(app).post('/api/auth/refresh').set('X-Forwarded-For', ip).send({});
      expect(res.status).toBe(400);
    }
    const limited = await request(app)
      .post('/api/auth/refresh')
      .set('X-Forwarded-For', ip)
      .send({});
    expectError(limited, 429, 'TOO_MANY_REQUESTS');
    // Login from the same IP is not blocked by the refresh bucket.
    const loginRes = await request(app).post('/api/auth/login').set('X-Forwarded-For', ip).send({});
    expect(loginRes.status).toBe(400);
    // Another IP still refreshes.
    const other = await request(app)
      .post('/api/auth/refresh')
      .set('X-Forwarded-For', '198.18.0.2')
      .send({});
    expect(other.status).toBe(400);
  });

  it('/reset-password has its own bucket (10 per hour), separate from forgot-password', async () => {
    const ip = '198.18.1.1';
    for (let i = 0; i < 10; i++) {
      const res = await request(app)
        .post('/api/auth/reset-password')
        .set('X-Forwarded-For', ip)
        .send({});
      expect(res.status).toBe(400);
    }
    const limited = await request(app)
      .post('/api/auth/reset-password')
      .set('X-Forwarded-For', ip)
      .send({});
    expectError(limited, 429, 'TOO_MANY_REQUESTS');
    const forgot = await request(app)
      .post('/api/auth/forgot-password')
      .set('X-Forwarded-For', ip)
      .send({ identifier: 'owner.one@ecotech.test' });
    expect(forgot.status).toBe(202);
  });
});
