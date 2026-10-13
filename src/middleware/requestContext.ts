// server/src/middleware/requestContext.ts
//
//   loadRequestContext   after `authenticate`: loads the caller's employee in the active shop ONCE
//                        (public.session_context(), one round trip), applies the per-request
//                        status gate and sets req.ctx. Handlers read req.ctx.db / req.ctx.orgId
//                        only (getCtx), never an org id from the client.
//                        Then resolves the POS device of the request (O03 deviceContext); the
//                        client in req.ctx carries that device and no other.
//   requestContext(opts) the same with options; { allowMustChangePassword: true } is for
//                        /auth/me and /auth/change-password.
//
// Why a gate on every request (F04 review): anyone can get a token straight from GoTrue with the
// public anon key and skip the API's login checks, so the shop and employee status are checked
// again here, not only at login. logout and select-shop use `authenticate` only (no gate), so a
// user of a closed shop can still log out or switch shops.

import type { Request, Response, NextFunction } from 'express';
import type { EmployeeRole } from '@ziadkhaled-wb/contracts';
import { dbFor } from './auth';
import { resolveDevice } from './deviceContext';
import { asyncHandler } from '../utils/asyncHandler';
import { AppError, ServerError, mapDbError, safeMessage, type ErrorCode } from '../utils/errors';
import { logger } from '../utils/logger';
import type { DbClient } from '../utils/supabase';

/** The tenant context of one request. `orgId` is the shop RLS scopes every query to. */
export interface RequestContext {
  userId: string;
  employeeId: string;
  orgId: string;
  role: EmployeeRole;
  defaultBranchId: string | null;
  /** employee_branches rows (branch scope is enforced by F06; OWNER has none). */
  branchIds: string[];
  mustChangePassword: boolean;
  /** Per-request client that runs as the caller in the active shop. */
  db: DbClient;
}

/** The refusals session_context() may return; anything else is a server error. */
const REFUSALS = new Set<ErrorCode>([
  'NOT_AN_EMPLOYEE',
  'SHOP_NOT_ALLOWED',
  'SHOP_SELECTION_REQUIRED',
  'ACCOUNT_DISABLED',
  'SHOP_INACTIVE',
  'ORG_SUSPENDED',
  'SUBSCRIPTION_EXPIRED',
]);

export interface RequestContextOptions {
  /** Let an employee with must_change_password through (me, change-password). */
  allowMustChangePassword?: boolean;
}

export function requestContext(options: RequestContextOptions = {}) {
  return asyncHandler(async (req: Request, _res: Response, next: NextFunction) => {
    if (!req.auth) throw new Error('loadRequestContext used before authenticate.');
    const db = dbFor(req);

    const { data, error } = await db.rpc('session_context').single();
    if (error) {
      const mapped = mapDbError(error);
      if (mapped) throw mapped;
      logger.error({ err: error }, 'loadRequestContext: session_context failed');
      throw ServerError('Request failed.');
    }

    if (data.refusal !== null) {
      const code = data.refusal as ErrorCode;
      if (!REFUSALS.has(code)) {
        logger.error({ refusal: data.refusal }, 'loadRequestContext: unknown refusal');
        throw ServerError('Request failed.');
      }
      throw new AppError(safeMessage(code), code);
    }

    if (data.employee_id === null || data.organization_id === null || data.role === null) {
      logger.error('loadRequestContext: session_context returned no employee and no refusal');
      throw ServerError('Request failed.');
    }

    const mustChangePassword = data.must_change_password === true;
    if (mustChangePassword && !options.allowMustChangePassword) {
      throw new AppError(safeMessage('MUST_CHANGE_PASSWORD'), 'MUST_CHANGE_PASSWORD');
    }

    // O03: only now, with the shop known, is a device token worth anything. With a device the
    // request gets a client that sends its id; without one no device id goes to the database.
    await resolveDevice(req, db);

    req.ctx = {
      userId: req.auth.userId,
      employeeId: data.employee_id,
      orgId: data.organization_id,
      role: data.role,
      defaultBranchId: data.default_branch_id,
      branchIds: data.branch_ids ?? [],
      mustChangePassword,
      db: req.device ? dbFor(req) : db,
    };
    next();
  });
}

/** The standard gate: every refusal, including MUST_CHANGE_PASSWORD. */
export const loadRequestContext = requestContext();

/** req.ctx, or a programming error when the route was mounted without loadRequestContext. */
export function getCtx(req: Request): RequestContext {
  if (!req.ctx) throw new Error('getCtx() called on a route without loadRequestContext.');
  return req.ctx;
}
