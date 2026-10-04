// loadRequestContext + getCtx. dbFor is mocked: session_context() answers what each test needs.
import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Request, Response, NextFunction } from 'express';

interface RpcResponse {
  data: unknown;
  error: unknown;
}

const db = vi.hoisted(() => {
  const response: RpcResponse = { data: null, error: null };
  return { response, rpc: vi.fn() };
});

vi.mock('./auth', () => ({
  dbFor: vi.fn(() => ({ rpc: db.rpc })),
}));

import { dbFor } from './auth';
import { getCtx, loadRequestContext, requestContext } from './requestContext';
import { AppError } from '../utils/errors';
import type { RequestHandler } from 'express';

const USER = '11111111-1111-4111-8111-111111111111';
const EMP = '22222222-2222-4222-8222-222222222222';
const ORG = '33333333-3333-4333-8333-333333333333';
const BRANCH = '44444444-4444-4444-8444-444444444444';

const okRow = {
  employee_id: EMP,
  organization_id: ORG,
  role: 'CASHIER',
  default_branch_id: BRANCH,
  branch_ids: [BRANCH],
  must_change_password: false,
  refusal: null,
};

function refused(refusal: string) {
  return {
    employee_id: null,
    organization_id: null,
    role: null,
    default_branch_id: null,
    branch_ids: null,
    must_change_password: null,
    refusal,
  };
}

function mockReq(auth = true): Request {
  return {
    headers: {},
    requestId: 'req-1',
    ...(auth ? { auth: { userId: USER, email: null, accessToken: 'jwt' } } : {}),
  } as unknown as Request;
}

/** Runs the middleware and resolves with the error passed to next (undefined on success). */
function run(req: Request, mw: RequestHandler = loadRequestContext): Promise<unknown> {
  return new Promise((resolve) => {
    const next: NextFunction = (err?: unknown) => resolve(err);
    void mw(req, {} as Response, next);
  });
}

beforeEach(() => {
  vi.mocked(dbFor).mockClear();
  db.response = { data: okRow, error: null };
  db.rpc.mockReset();
  db.rpc.mockImplementation(() => ({ single: () => Promise.resolve(db.response) }));
});

describe('loadRequestContext', () => {
  it('loads the context once with session_context() and sets req.ctx', async () => {
    const req = mockReq();
    expect(await run(req)).toBeUndefined();
    expect(db.rpc).toHaveBeenCalledTimes(1);
    expect(db.rpc).toHaveBeenCalledWith('session_context');
    expect(req.ctx).toEqual({
      userId: USER,
      employeeId: EMP,
      orgId: ORG,
      role: 'CASHIER',
      defaultBranchId: BRANCH,
      branchIds: [BRANCH],
      mustChangePassword: false,
      db: { rpc: db.rpc },
    });
  });

  it('req.ctx.db is the per-request client from dbFor (caller JWT + x-org-id)', async () => {
    const req = mockReq();
    await run(req);
    expect(dbFor).toHaveBeenCalledWith(req);
    expect(req.ctx?.db).toBe(vi.mocked(dbFor).mock.results[0]?.value);
  });

  it('no branch rows (OWNER) -> branchIds []', async () => {
    db.response = { data: { ...okRow, role: 'OWNER', branch_ids: null }, error: null };
    const req = mockReq();
    await run(req);
    expect(req.ctx?.branchIds).toEqual([]);
  });

  it.each([
    ['NOT_AN_EMPLOYEE', 403],
    ['SHOP_NOT_ALLOWED', 403],
    ['SHOP_SELECTION_REQUIRED', 400],
    ['ACCOUNT_DISABLED', 403],
    ['SHOP_INACTIVE', 403],
    ['SUBSCRIPTION_EXPIRED', 403],
  ])('refusal %s -> %i with that code, no req.ctx', async (code, status) => {
    db.response = { data: refused(code), error: null };
    const req = mockReq();
    const err = await run(req);
    expect(err).toBeInstanceOf(AppError);
    expect(err).toMatchObject({ statusCode: status, code });
    expect(req.ctx).toBeUndefined();
  });

  it('a refusal outside the known list -> 500, never passed through', async () => {
    db.response = { data: refused('PERMISSION_DENIED'), error: null };
    expect(await run(mockReq())).toMatchObject({ statusCode: 500, code: 'INTERNAL' });
  });

  it('must_change_password -> 403 MUST_CHANGE_PASSWORD on a normal route', async () => {
    db.response = { data: { ...okRow, must_change_password: true }, error: null };
    const req = mockReq();
    expect(await run(req)).toMatchObject({ statusCode: 403, code: 'MUST_CHANGE_PASSWORD' });
    expect(req.ctx).toBeUndefined();
  });

  it('must_change_password passes with allowMustChangePassword (me, change-password)', async () => {
    db.response = { data: { ...okRow, must_change_password: true }, error: null };
    const req = mockReq();
    expect(await run(req, requestContext({ allowMustChangePassword: true }))).toBeUndefined();
    expect(req.ctx?.mustChangePassword).toBe(true);
  });

  it('allowMustChangePassword still applies every other refusal', async () => {
    db.response = { data: refused('SHOP_INACTIVE'), error: null };
    const err = await run(mockReq(), requestContext({ allowMustChangePassword: true }));
    expect(err).toMatchObject({ statusCode: 403, code: 'SHOP_INACTIVE' });
  });

  it('a DB error carrying a contract code -> that code', async () => {
    db.response = { data: null, error: { message: 'NOT_AN_EMPLOYEE', code: '42501' } };
    expect(await run(mockReq())).toMatchObject({ statusCode: 403, code: 'NOT_AN_EMPLOYEE' });
  });

  it('any other DB error -> 500 with a generic message (raw message never exposed)', async () => {
    db.response = { data: null, error: { message: 'connection reset by peer', code: '08006' } };
    const err = await run(mockReq());
    expect(err).toMatchObject({ statusCode: 500, code: 'INTERNAL' });
    expect((err as Error).message).not.toMatch(/connection reset/);
  });

  it('a row with no employee and no refusal -> 500', async () => {
    db.response = { data: { ...refused('x'), refusal: null }, error: null };
    expect(await run(mockReq())).toMatchObject({ statusCode: 500 });
  });

  it('used before authenticate -> programming error, no DB call', async () => {
    const err = await run(mockReq(false));
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).toMatch(/before authenticate/);
    expect(db.rpc).not.toHaveBeenCalled();
  });
});

describe('getCtx', () => {
  it('returns req.ctx after loadRequestContext', async () => {
    const req = mockReq();
    await run(req);
    expect(getCtx(req).orgId).toBe(ORG);
  });

  it('throws when the route has no loadRequestContext', () => {
    expect(() => getCtx(mockReq())).toThrow(/without loadRequestContext/);
  });
});
