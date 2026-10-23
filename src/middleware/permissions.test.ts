import { describe, it, expect, vi } from 'vitest';
import express, { type RequestHandler } from 'express';
import request from 'supertest';
import { PERMISSION_KEYS, type PermissionKey } from '@ziadkhaled-wb/contracts';
import { authenticatedOnly, publicRoute, requirePermission, routeAccessOf } from './permissions';
import { errorHandler } from './errorHandler';
import type { RequestContext } from './requestContext';
import type { DbClient } from '../utils/supabase';

const ORG = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BRANCH = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

type RpcReply = { data: unknown; error: unknown };

/** A db whose rpc('my_permissions').single() answers `reply`; counts the calls. */
function fakeDb(reply: RpcReply) {
  const rpc = vi.fn(() => ({ single: () => Promise.resolve(reply) }));
  return { db: { rpc } as unknown as DbClient, rpc };
}

function appWith(db: DbClient, ...chain: RequestHandler[]) {
  const app = express();
  app.use((req, _res, next) => {
    req.auth = { userId: 'u1', email: null, accessToken: 't' };
    const ctx: RequestContext = {
      userId: 'u1',
      employeeId: 'e1',
      orgId: ORG,
      role: 'CASHIER',
      defaultBranchId: null,
      branchIds: [],
      mustChangePassword: false,
      db,
    };
    req.ctx = ctx;
    next();
  });
  app.get('/x', ...chain, (_req, res) => {
    res.json({ ok: true });
  });
  app.use(errorHandler);
  return app;
}

const row = (keys: string[]) => ({
  data: { keys, branch_ids: [BRANCH], all_branches: false },
  error: null,
});

describe('requirePermission: every one of the 65 contract keys (N03 collection.reverse, N04 overdue.view and overdue.handle, S08 offline.resolve)', () => {
  it('the contract has 65 keys', () => {
    expect(PERMISSION_KEYS).toHaveLength(65);
  });

  it.each(PERMISSION_KEYS.map((k) => [k]))(
    '%s: missing -> 403 PERMISSION_DENIED with the key; present -> next()',
    async (key) => {
      const others = PERMISSION_KEYS.filter((k) => k !== key);
      const denied = await request(appWith(fakeDb(row(others)).db, requirePermission(key))).get(
        '/x',
      );
      expect(denied.status).toBe(403);
      expect(denied.body.error.code).toBe('PERMISSION_DENIED');
      expect(denied.body.error.details).toEqual({ permission: key });

      const allowed = await request(appWith(fakeDb(row([key])).db, requirePermission(key))).get(
        '/x',
      );
      expect(allowed.status).toBe(200);
      expect(allowed.body).toEqual({ ok: true });
    },
  );
});

describe('requirePermission: behaviour', () => {
  it('reads my_permissions once per request, however many checks run', async () => {
    const { db, rpc } = fakeDb(row(['sale.create', 'sale.void']));
    const res = await request(
      appWith(db, requirePermission('sale.create'), requirePermission('sale.void')),
    ).get('/x');
    expect(res.status).toBe(200);
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc).toHaveBeenCalledWith('my_permissions');
  });

  it('a DB error carrying a contract code -> that code', async () => {
    const { db } = fakeDb({ data: null, error: { message: 'NOT_AN_EMPLOYEE' } });
    const res = await request(appWith(db, requirePermission('sale.create'))).get('/x');
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('NOT_AN_EMPLOYEE');
  });

  it('any other DB error -> 500, raw message never exposed', async () => {
    const { db } = fakeDb({ data: null, error: { message: 'relation "x" does not exist' } });
    const res = await request(appWith(db, requirePermission('sale.create'))).get('/x');
    expect(res.status).toBe(500);
    expect(JSON.stringify(res.body)).not.toContain('relation');
  });

  it('a key the contract does not know (DB drift) -> 500, not silently allowed', async () => {
    const { db } = fakeDb(row(['sale.create', 'sale.teleport']));
    const res = await request(appWith(db, requirePermission('sale.create'))).get('/x');
    expect(res.status).toBe(500);
  });

  it('used without loadRequestContext -> programming error (500), no DB call', async () => {
    const app = express();
    app.get('/x', requirePermission('sale.create'), (_req, res) => {
      res.json({});
    });
    app.use(errorHandler);
    const res = await request(app).get('/x');
    expect(res.status).toBe(500);
  });
});

describe('route markers', () => {
  it('each marker says what it is', () => {
    expect(routeAccessOf(publicRoute())).toEqual({ kind: 'public' });
    expect(routeAccessOf(authenticatedOnly())).toEqual({ kind: 'authenticated' });
    const key: PermissionKey = 'employee.manage';
    expect(routeAccessOf(requirePermission(key))).toEqual({ kind: 'permission', key });
    expect(routeAccessOf(() => undefined)).toBeUndefined();
    expect(routeAccessOf('not a handler')).toBeUndefined();
  });

  it('publicRoute lets the request through', async () => {
    const app = express();
    app.get('/x', publicRoute(), (_req, res) => {
      res.json({ ok: true });
    });
    expect((await request(app).get('/x')).status).toBe(200);
  });

  it('authenticatedOnly before authenticate is a programming error', async () => {
    const app = express();
    app.get('/x', authenticatedOnly(), (_req, res) => {
      res.json({ ok: true });
    });
    app.use(errorHandler);
    expect((await request(app).get('/x')).status).toBe(500);
  });
});
