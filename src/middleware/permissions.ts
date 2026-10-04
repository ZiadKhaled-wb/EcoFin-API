// server/src/middleware/permissions.ts
//
// F06 / D19: every route carries exactly one access marker, and `npm run check:permissions`
// fails CI when one is missing.
//
//   publicRoute()            no session needed (health, login, refresh, forgot, reset)
//   authenticatedOnly()      any signed-in caller; mount after `authenticate`
//   requirePermission(key)   the caller's effective permissions (role default +/- override, OWNER
//                            has all) must include `key`, else 403 PERMISSION_DENIED with the key
//                            in details. Mount after loadRequestContext.
//
// Effective permissions come from public.my_permissions() (F06 migration), read at most once per
// request and shared with GET /api/me/permissions. The database stays the real check: every
// write function starts with app.require_permission(...) itself.

import type { Request, Response, NextFunction, RequestHandler } from 'express';
import type { PermissionKey } from '@ziadkhaled-wb/contracts';
import { getCtx } from './requestContext';
import { getMyPermissions } from '../services/permissions.service';
import { asyncHandler } from '../utils/asyncHandler';
import { AppError, safeMessage } from '../utils/errors';

export type RouteAccess =
  { kind: 'public' } | { kind: 'authenticated' } | { kind: 'permission'; key: PermissionKey };

const ACCESS = Symbol.for('ecofin.routeAccess');

function mark(handler: RequestHandler, access: RouteAccess): RequestHandler {
  Object.defineProperty(handler, ACCESS, { value: access, enumerable: false });
  return handler;
}

/** The access marker carried by a route handler, if it is one. */
export function routeAccessOf(handler: unknown): RouteAccess | undefined {
  if (typeof handler !== 'function') return undefined;
  return (handler as unknown as Record<symbol, RouteAccess | undefined>)[ACCESS];
}

export function publicRoute(): RequestHandler {
  return mark((_req, _res, next) => next(), { kind: 'public' });
}

export function authenticatedOnly(): RequestHandler {
  return mark(
    (req, _res, next) => {
      if (!req.auth) throw new Error('authenticatedOnly() used before authenticate.');
      next();
    },
    { kind: 'authenticated' },
  );
}

export function requirePermission(key: PermissionKey): RequestHandler {
  return mark(
    asyncHandler(async (req: Request, _res: Response, next: NextFunction) => {
      const { keys } = await getMyPermissions(getCtx(req));
      if (!keys.includes(key)) {
        throw new AppError(safeMessage('PERMISSION_DENIED'), 'PERMISSION_DENIED', undefined, {
          permission: key,
        });
      }
      next();
    }),
    { kind: 'permission', key },
  );
}
