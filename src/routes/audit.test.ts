// GET /api/audit with the real router, validate() and requirePermission; authenticate and the
// request context are stubbed, the DB is the chainable Supabase mock.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import express, { type NextFunction, type Request, type Response } from 'express';
import request from 'supertest';
import { createSupabaseMock, type SupabaseMock } from '../test/supabase-mock';
import type { RequestContext } from '../middleware/requestContext';
import type { DbClient } from '../utils/supabase';

const ORG = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const EMP = '11111111-1111-4111-8111-111111111111';
const db: { current: SupabaseMock | null } = vi.hoisted(() => ({ current: null }));

vi.mock('../middleware/auth', () => ({
  authenticate: (req: Request, _res: Response, next: NextFunction) => {
    req.auth = { userId: 'u1', email: null, accessToken: 't' };
    next();
  },
}));
vi.mock('../middleware/requestContext', () => ({
  loadRequestContext: (req: Request, _res: Response, next: NextFunction) => {
    const ctx: RequestContext = {
      userId: 'u1',
      employeeId: EMP,
      orgId: ORG,
      role: 'OWNER',
      defaultBranchId: null,
      branchIds: [],
      mustChangePassword: false,
      db: db.current as unknown as DbClient,
    };
    req.ctx = ctx;
    next();
  },
  getCtx: (req: Request) => {
    if (!req.ctx) throw new Error('no ctx');
    return req.ctx;
  },
}));

const { default: auditRoutes } = await import('./audit');
const { errorHandler } = await import('../middleware/errorHandler');

const app = express();
app.use('/api/audit', auditRoutes);
app.use(errorHandler);

const perms = (keys: string[]) => ({
  data: { keys, branch_ids: [], all_branches: true },
  error: null,
});
const dbRow = {
  id: 7,
  branch_id: null,
  employee_id: EMP,
  super_admin_id: null,
  device_id: null,
  ip: '203.0.113.7',
  user_agent: 'ua',
  request_id: 'req-1',
  action: 'auth.login',
  entity_type: null,
  entity_id: null,
  severity: 'info',
  reason: null,
  before: null,
  after: null,
  created_at: '2026-10-04 13:30:12.398+00',
  actor: { full_name: 'Owner One' },
};

beforeEach(() => {
  db.current = createSupabaseMock();
  db.current.rpc.mockImplementation(() => db.current);
});

describe('GET /api/audit', () => {
  it('without audit.view -> 403 PERMISSION_DENIED, the log is never read', async () => {
    db.current!.queue(perms(['sale.create']));
    const res = await request(app).get('/api/audit');
    expect(res.status).toBe(403);
    expect(res.body.error).toMatchObject({
      code: 'PERMISSION_DENIED',
      details: { permission: 'audit.view' },
    });
    expect(db.current!.from).not.toHaveBeenCalled();
  });

  it('with audit.view: parsed filters reach the query, newest first, contract rows back', async () => {
    db.current!.queue(perms(['audit.view']), { data: [dbRow], error: null, count: 41 } as never);
    const res = await request(app).get('/api/audit').query({
      action: 'auth.login',
      actorEmployeeId: EMP,
      from: '2026-10-01T00:00:00Z',
      to: '2026-10-05T00:00:00Z',
      page: '3',
      pageSize: '20',
    });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    const m = db.current!;
    expect(m.from).toHaveBeenCalledWith('audit_log');
    expect(m.eq).toHaveBeenCalledWith('organization_id', ORG); // from the session, not the request
    expect(m.eq).toHaveBeenCalledWith('action', 'auth.login');
    expect(m.eq).toHaveBeenCalledWith('employee_id', EMP);
    expect(m.gte).toHaveBeenCalledWith('created_at', '2026-10-01T00:00:00Z');
    expect(m.order).toHaveBeenCalledWith('created_at', { ascending: false });
    expect(res.body).toEqual({
      items: [
        expect.objectContaining({
          id: 7,
          employeeId: EMP,
          actorName: 'Owner One',
          ip: '203.0.113.7',
          createdAt: '2026-10-04T13:30:12.398Z',
        }),
      ],
      page: 3,
      pageSize: 20,
      total: 41,
    });
  });

  it.each([
    ['pageSize over 100', { pageSize: '500' }],
    ['a bad entity id', { entityId: 'nope' }],
    ['from after to', { from: '2026-10-05T00:00:00Z', to: '2026-10-01T00:00:00Z' }],
    ['an unknown filter', { sort: 'id' }],
    ['organization_id', { organization_id: ORG }],
    ['orgId', { orgId: ORG }],
  ])('%s -> 400 VALIDATION_FAILED, the log is never read', async (_name, query) => {
    db.current!.queue(perms(['audit.view']));
    const res = await request(app).get('/api/audit').query(query);
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
    expect(db.current!.from).not.toHaveBeenCalled();
  });

  it('a DB error is a 500 without the raw message', async () => {
    db.current!.queue(perms(['audit.view']), { data: null, error: { message: 'boom detail' } });
    const res = await request(app).get('/api/audit');
    expect(res.status).toBe(500);
    expect(JSON.stringify(res.body)).not.toContain('boom');
  });
});
