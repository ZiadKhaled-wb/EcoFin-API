import { describe, it, expect, vi, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';
import { ZodError, z } from 'zod';
import { ErrorResponse, HealthResponse } from '@ziadkhaled-wb/contracts';

const db = vi.hoisted(() => ({ query: vi.fn() }));
vi.mock('./utils/supabase', () => ({
  supabaseAdmin: {
    from: () => ({ select: () => ({ limit: () => ({ abortSignal: () => db.query() }) }) }),
  },
  supabaseAnon: {},
  supabaseUser: () => ({}),
}));

import { createApp } from './app';
import { errorHandler, notFoundHandler } from './middleware/errorHandler';
import { requestId } from './middleware/requestId';
import { AppError } from './utils/errors';

const ALLOWED = 'https://app.example.com';
const app = createApp({ env: { TRUST_PROXY: 1, CORS_ALLOWED_ORIGINS: [ALLOWED] } });

/** A small app with the real middleware and routes that fail in specific ways. */
function failingApp() {
  const a = express();
  a.use(requestId());
  a.use(express.json());
  a.get('/app-error', () => {
    throw new AppError('Not enough stock', 'OUT_OF_STOCK');
  });
  a.get('/db-error', () => {
    throw Object.assign(new Error('OUT_OF_STOCK: product 8f1c needs 3, has 1'), {
      details: 'Key (id)=(8f1c)',
      hint: 'raw-db-hint',
    });
  });
  a.get('/unknown', () => {
    throw new Error('relation "secret_table" does not exist');
  });
  a.post('/zod', (req) => {
    z.object({ name: z.string(), qty: z.number() }).parse(req.body);
  });
  a.get('/zod-foreign', () => {
    // A ZodError from another zod copy (the contracts package): not instanceof, same name/issues.
    throw Object.assign(new Error('[]'), {
      name: 'ZodError',
      issues: [{ path: ['tenantSlug'], code: 'custom', message: 'tenantSlug is required' }],
    });
  });
  a.get('/zod-direct', () => {
    throw new ZodError([]);
  });
  a.get('/leaky-details', () => {
    throw new AppError('Bad', 'BAD_REQUEST', 400, { password: 'hunter2', field: 'x' });
  });
  a.use(notFoundHandler);
  a.use(errorHandler);
  return a;
}

function expectContractError(body: unknown, code: string) {
  const parsed = ErrorResponse.parse(body);
  expect(parsed.error.code).toBe(code);
  expect(parsed.error.requestId).toBeTruthy();
  return parsed;
}

describe('error handler', () => {
  const a = failingApp();

  it('invalid JSON body -> 400 BAD_REQUEST in the contract shape', async () => {
    const res = await request(a)
      .post('/zod')
      .set('Content-Type', 'application/json')
      .send('{"name":');
    expect(res.status).toBe(400);
    expectContractError(res.body, 'BAD_REQUEST');
  });

  it('invalid JSON body through createApp', async () => {
    const res = await request(app)
      .post('/api/auth/login')
      .set('Content-Type', 'application/json')
      .send('{not json');
    expect(res.status).toBe(400);
    expectContractError(res.body, 'BAD_REQUEST');
  });

  it('zod failure -> 400 VALIDATION_FAILED with field issues in details', async () => {
    const res = await request(a).post('/zod').send({ name: 1 });
    expect(res.status).toBe(400);
    const parsed = expectContractError(res.body, 'VALIDATION_FAILED');
    const details = parsed.error.details as { path: string }[];
    expect(details.map((d) => d.path).sort()).toEqual(['name', 'qty']);
  });

  it('a ZodError from another zod copy (by name) -> 400 VALIDATION_FAILED, not 500', async () => {
    const res = await request(a).get('/zod-foreign');
    expect(res.status).toBe(400);
    const parsed = expectContractError(res.body, 'VALIDATION_FAILED');
    expect(parsed.error.details).toEqual([
      { path: 'tenantSlug', code: 'custom', message: 'tenantSlug is required' },
    ]);
  });

  it('AppError OUT_OF_STOCK -> 409 with its code', async () => {
    const res = await request(a).get('/app-error');
    expect(res.status).toBe(409);
    expectContractError(res.body, 'OUT_OF_STOCK');
  });

  it('database error "OUT_OF_STOCK: ..." -> 409 OUT_OF_STOCK with no raw DB text', async () => {
    // A fixed request id: a random one can contain "8f1c" and match the leak check by chance.
    const res = await request(a).get('/db-error').set('x-request-id', 'req-db-error');
    expect(res.status).toBe(409);
    expectContractError(res.body, 'OUT_OF_STOCK');
    expect(JSON.stringify(res.body)).not.toMatch(/8f1c|raw-db-hint|Key \(id\)/);
  });

  it('unknown error -> 500 INTERNAL, generic message, request id, nothing leaked', async () => {
    const res = await request(a).get('/unknown').set('x-request-id', 'req-123');
    expect(res.status).toBe(500);
    const parsed = expectContractError(res.body, 'INTERNAL');
    expect(parsed.error.requestId).toBe('req-123');
    expect(JSON.stringify(res.body)).not.toContain('secret_table');
  });

  it('redacts sensitive keys in AppError details', async () => {
    const res = await request(a).get('/leaky-details');
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).not.toContain('hunter2');
  });

  it('unknown route -> 404 NOT_FOUND', async () => {
    const res = await request(app).get('/nope');
    expect(res.status).toBe(404);
    expectContractError(res.body, 'NOT_FOUND');
  });
});

describe('request id', () => {
  it('echoes a safe x-request-id', async () => {
    const res = await request(app).get('/nope').set('x-request-id', 'abc.DEF_123-x');
    expect(res.headers['x-request-id']).toBe('abc.DEF_123-x');
  });

  it('replaces an unsafe or over-long id with a UUID', async () => {
    for (const bad of ['has space', 'semi;colon', 'a'.repeat(129), '<script>']) {
      const res = await request(app).get('/nope').set('x-request-id', bad);
      expect(res.headers['x-request-id']).toMatch(/^[0-9a-f-]{36}$/);
      expect((res.body as { error: { requestId: string } }).error.requestId).toBe(
        res.headers['x-request-id'],
      );
    }
  });

  it('generates a UUID when none is sent', async () => {
    const res = await request(app).get('/nope');
    expect(res.headers['x-request-id']).toMatch(/^[0-9a-f-]{36}$/);
  });
});

describe('GET /health', () => {
  beforeEach(() => {
    db.query.mockReset();
  });

  it('200 ok when the database answers, with no auth', async () => {
    db.query.mockResolvedValue({ data: [], error: null });
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(HealthResponse.parse(res.body)).toMatchObject({ status: 'ok', db: 'ok' });
    expect(Object.keys(res.body as object).sort()).toEqual(['db', 'status', 'time', 'version']);
  });

  it('503 degraded when the database returns an error, without leaking it', async () => {
    db.query.mockResolvedValue({
      data: null,
      error: { message: 'password authentication failed' },
    });
    const res = await request(app).get('/health');
    expect(res.status).toBe(503);
    expect(HealthResponse.parse(res.body)).toMatchObject({ status: 'degraded', db: 'down' });
    expect(JSON.stringify(res.body)).not.toContain('password');
  });

  it('503 when the database call throws', async () => {
    db.query.mockRejectedValue(new Error('ECONNREFUSED'));
    const res = await request(app).get('/health');
    expect(res.status).toBe(503);
    expect(HealthResponse.parse(res.body).db).toBe('down');
  });
});

describe('security headers and CORS', () => {
  it('sets helmet headers and hides x-powered-by', async () => {
    const res = await request(app).get('/nope');
    expect(res.headers['x-content-type-options']).toBe('nosniff');
    expect(res.headers['strict-transport-security']).toBeTruthy();
    expect(res.headers['x-frame-options']).toBeTruthy();
    expect(res.headers['content-security-policy']).toBeTruthy();
    expect(res.headers['x-powered-by']).toBeUndefined();
  });

  it('allows an origin in the list (with credentials) and answers its preflight', async () => {
    const res = await request(app).get('/nope').set('Origin', ALLOWED);
    expect(res.headers['access-control-allow-origin']).toBe(ALLOWED);
    expect(res.headers['access-control-allow-credentials']).toBe('true');
    const pre = await request(app)
      .options('/api/auth/login')
      .set('Origin', ALLOWED)
      .set('Access-Control-Request-Method', 'POST');
    expect(pre.headers['access-control-allow-origin']).toBe(ALLOWED);
  });

  it('preflight allows the headers the API needs', async () => {
    const pre = await request(app)
      .options('/api/auth/login')
      .set('Origin', ALLOWED)
      .set('Access-Control-Request-Method', 'POST');
    const allowed = String(pre.headers['access-control-allow-headers']).toLowerCase();
    for (const header of [
      'content-type',
      'authorization',
      'x-request-id',
      'x-org-id',
      'idempotency-key',
      'x-device-token',
    ]) {
      expect(allowed).toContain(header);
    }
    const actual = await request(app).get('/nope').set('Origin', ALLOWED);
    expect(String(actual.headers['access-control-expose-headers']).toLowerCase()).toContain(
      'x-request-id',
    );
  });

  it('gives no CORS headers to an origin that is not in the list, and never uses *', async () => {
    const res = await request(app).get('/nope').set('Origin', 'https://evil.example.com');
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
    const pre = await request(app)
      .options('/api/auth/login')
      .set('Origin', 'https://evil.example.com')
      .set('Access-Control-Request-Method', 'POST');
    expect(pre.headers['access-control-allow-origin']).toBeUndefined();
  });
});

describe('trust proxy', () => {
  it('is taken from the env', () => {
    expect(app.get('trust proxy')).toBe(1);
    const direct = createApp({ env: { TRUST_PROXY: false, CORS_ALLOWED_ORIGINS: [ALLOWED] } });
    expect(direct.get('trust proxy')).toBe(false);
  });
});
