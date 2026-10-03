// authenticate + dbFor. @supabase/supabase-js createClient is mocked, so every client the code
// creates is recorded with its options, and getUser answers what each test needs.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Request, Response, NextFunction } from 'express';

const created = vi.hoisted(() => ({
  clients: [] as { key: string; options: { global?: { headers?: Record<string, string> } } }[],
  getUser: vi.fn(),
}));

vi.mock('@supabase/supabase-js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@supabase/supabase-js')>();
  return {
    ...actual,
    createClient: vi.fn(
      (_url: string, key: string, options: (typeof created.clients)[number]['options']) => {
        const client = { key, options, auth: { getUser: created.getUser } };
        created.clients.push(client);
        return client;
      },
    ),
  };
});

import { AuthApiError, AuthError, AuthSessionMissingError } from '@supabase/supabase-js';
import { authenticate, dbFor } from './auth';
import { AppError } from '../utils/errors';

const USER_1 = '11111111-1111-4111-8111-111111111111';
const USER_2 = '22222222-2222-4222-8222-222222222222';
const ORG = '33333333-3333-4333-8333-333333333333';

function jwt(payload: Record<string, unknown>): string {
  const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${b64({ alg: 'HS256' })}.${b64(payload)}.sig`;
}
const future = Math.floor(Date.now() / 1000) + 3600;
const TOKEN_1 = jwt({ sub: USER_1, exp: future });
const TOKEN_2 = jwt({ sub: USER_2, exp: future });

function mockReq(headers: Record<string, string | string[]> = {}): Request {
  return {
    headers,
    requestId: 'req-1',
    ip: '203.0.113.5',
    get: (name: string) => (name.toLowerCase() === 'user-agent' ? 'vitest-agent' : undefined),
  } as unknown as Request;
}

/** Runs the middleware and resolves with the error passed to next (undefined on success). */
function run(req: Request): Promise<unknown> {
  return new Promise((resolve) => {
    const next: NextFunction = (err?: unknown) => resolve(err);
    authenticate(req, {} as Response, next);
  });
}

function userFor(token: string) {
  const sub = token === TOKEN_1 ? USER_1 : USER_2;
  return { data: { user: { id: sub, email: `${sub}@x.test` } }, error: null };
}

beforeEach(() => {
  created.clients = [];
  created.getUser.mockReset();
  created.getUser.mockImplementation((token: string) => Promise.resolve(userFor(token)));
});

describe('authenticate', () => {
  it('no Authorization header -> 401 UNAUTHORIZED, Supabase not called', async () => {
    const err = await run(mockReq());
    expect(err).toBeInstanceOf(AppError);
    expect(err).toMatchObject({ statusCode: 401, code: 'UNAUTHORIZED' });
    expect(created.getUser).not.toHaveBeenCalled();
  });

  it('a non-Bearer header -> 401 UNAUTHORIZED', async () => {
    expect(await run(mockReq({ authorization: 'Basic abc' }))).toMatchObject({
      code: 'UNAUTHORIZED',
    });
  });

  it('validates the token server-side with Supabase Auth getUser(jwt) and sets req.auth', async () => {
    const req = mockReq({ authorization: `Bearer ${TOKEN_1}` });
    expect(await run(req)).toBeUndefined();
    expect(created.getUser).toHaveBeenCalledWith(TOKEN_1);
    expect(req.auth).toEqual({ userId: USER_1, email: `${USER_1}@x.test`, accessToken: TOKEN_1 });
    expect(req.user).toEqual({ id: USER_1, email: `${USER_1}@x.test` });
  });

  it('a token getUser rejects (revoked session) -> 401 TOKEN_INVALID', async () => {
    created.getUser.mockResolvedValue({
      data: { user: null },
      error: new AuthApiError(
        'Session from session_id claim in JWT does not exist',
        403,
        'session_not_found',
      ),
    });
    const req = mockReq({ authorization: `Bearer ${TOKEN_1}` });
    expect(await run(req)).toMatchObject({ statusCode: 401, code: 'TOKEN_INVALID' });
    expect(req.auth).toBeUndefined();
  });

  it('a logged-out session (auth-js AuthSessionMissingError from GoTrue session_not_found) -> 401 TOKEN_INVALID', async () => {
    created.getUser.mockResolvedValue({
      data: { user: null },
      error: new AuthSessionMissingError(),
    });
    expect(await run(mockReq({ authorization: `Bearer ${TOKEN_1}` }))).toMatchObject({
      statusCode: 401,
      code: 'TOKEN_INVALID',
    });
  });

  it('an expired token -> 401 TOKEN_EXPIRED', async () => {
    created.getUser.mockResolvedValue({
      data: { user: null },
      error: new AuthApiError('token is expired', 403, 'bad_jwt'),
    });
    const expired = jwt({ sub: USER_1, exp: Math.floor(Date.now() / 1000) - 10 });
    expect(await run(mockReq({ authorization: `Bearer ${expired}` }))).toMatchObject({
      statusCode: 401,
      code: 'TOKEN_EXPIRED',
    });
  });

  it('Supabase Auth unreachable -> 500 (fails closed, not a 401)', async () => {
    created.getUser.mockResolvedValue({
      data: { user: null },
      error: new AuthError('fetch failed'),
    });
    expect(await run(mockReq({ authorization: `Bearer ${TOKEN_1}` }))).toMatchObject({
      statusCode: 500,
    });
  });

  it.each([
    ['429 (Supabase Auth rate limit)', 429],
    ['500', 500],
    ['503', 503],
  ])('Supabase Auth answering %s -> 500 INTERNAL, never TOKEN_INVALID', async (_name, status) => {
    created.getUser.mockResolvedValue({
      data: { user: null },
      error: new AuthApiError('upstream trouble', status, undefined),
    });
    const err = await run(mockReq({ authorization: `Bearer ${TOKEN_1}` }));
    expect(err).toMatchObject({ statusCode: 500, code: 'INTERNAL' });
  });

  it('accepts x-org-id only as a UUID', async () => {
    const ok = mockReq({ authorization: `Bearer ${TOKEN_1}`, 'x-org-id': ORG.toUpperCase() });
    expect(await run(ok)).toBeUndefined();
    expect(ok.auth?.orgId).toBe(ORG);

    for (const bad of ['not-a-uuid', "1' OR '1'='1", [ORG, ORG]]) {
      const req = mockReq({ authorization: `Bearer ${TOKEN_1}`, 'x-org-id': bad });
      expect(await run(req)).toMatchObject({ statusCode: 400, code: 'VALIDATION_FAILED' });
      expect(req.auth).toBeUndefined();
    }
  });

  it('every token check uses its own fresh anon client', async () => {
    await run(mockReq({ authorization: `Bearer ${TOKEN_1}` }));
    await run(mockReq({ authorization: `Bearer ${TOKEN_2}` }));
    expect(created.clients).toHaveLength(2);
    expect(created.clients[0]).not.toBe(created.clients[1]);
  });
});

describe('two users, one after the other (no shared session)', () => {
  it('each request gets its own client carrying its own JWT', async () => {
    const req1 = mockReq({ authorization: `Bearer ${TOKEN_1}` });
    const req2 = mockReq({ authorization: `Bearer ${TOKEN_2}`, 'x-org-id': ORG });
    await run(req1);
    await run(req2);

    const db1 = dbFor(req1) as unknown as (typeof created.clients)[number];
    const db2 = dbFor(req2) as unknown as (typeof created.clients)[number];
    expect(db1).not.toBe(db2);
    expect(db1.options.global?.headers?.['Authorization']).toBe(`Bearer ${TOKEN_1}`);
    expect(db2.options.global?.headers?.['Authorization']).toBe(`Bearer ${TOKEN_2}`);
    expect(db1.options.global?.headers?.['x-org-id']).toBeUndefined();
    expect(db2.options.global?.headers?.['x-org-id']).toBe(ORG);
    // Request details for the audit row.
    expect(db1.options.global?.headers).toMatchObject({
      'x-forwarded-for': '203.0.113.5',
      'user-agent': 'vitest-agent',
      'x-request-id': 'req-1',
    });
    // Asking again builds yet another client: nothing is cached per process.
    expect(dbFor(req1)).not.toBe(db1);
  });

  it('dbFor refuses to run before authenticate', () => {
    expect(() => dbFor(mockReq())).toThrow(/before authenticate/);
  });
});
