// HTTP-level checks of /api/auth/* through the real app (validation, status codes, error shape).
// Supabase and the service-role module are mocked.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import request from 'supertest';
import { AuthApiError } from '@supabase/supabase-js';
import { Ack, ErrorResponse } from '@ecotech/contracts';

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
vi.mock('../utils/supabase', () => ({
  createAuthClient: () => ({ auth: authApi }),
  supabaseForRequest: () => ({ rpc: () => Promise.resolve({ data: [], error: null }) }),
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
