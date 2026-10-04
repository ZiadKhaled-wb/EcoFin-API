// server/src/middleware/noClientOrg.ts
//
// F05: the shop always comes from the session (req.ctx.orgId), never from the client. Any
// request whose body or query carries organization_id / organizationId / orgId (at any depth,
// any case or separator) is refused with 400 VALIDATION_FAILED before a handler runs.
// Route params are checked by validate() (they only exist once a route matched).
//
// One exception (D23): POST /api/auth/select-shop takes the shop to switch to as body.orgId.
// The database still decides whether the login belongs to that shop.

import type { Request, Response, NextFunction } from 'express';
import { BadRequest } from '../utils/errors';

/** organization_id, organizationId, orgId, ORG-ID, ... -> 'organizationid' | 'orgid'. */
function isOrgKey(key: string): boolean {
  const k = key.toLowerCase().replace(/[^a-z]/g, '');
  return k === 'organizationid' || k === 'orgid';
}

/** Path of the first org key found, e.g. 'body.lines.0.organization_id'. */
export function findOrgKey(value: unknown, path: string, depth = 0): string | undefined {
  if (depth > 20 || value === null || typeof value !== 'object') return undefined;
  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    const here = `${path}.${key}`;
    if (isOrgKey(key)) return here;
    const nested = findOrgKey(child, here, depth + 1);
    if (nested) return nested;
  }
  return undefined;
}

/** Body keys a route may legitimately send (method + path as mounted). */
const BODY_EXCEPTIONS: Record<string, readonly string[]> = {
  'POST /api/auth/select-shop': ['orgId'],
};

export function noClientOrg(req: Request, _res: Response, next: NextFunction) {
  const allowed = BODY_EXCEPTIONS[`${req.method} ${req.path}`] ?? [];
  let body: unknown = req.body;
  if (allowed.length > 0 && body !== null && typeof body === 'object' && !Array.isArray(body)) {
    body = Object.fromEntries(
      Object.entries(body as Record<string, unknown>).filter(([k]) => !allowed.includes(k)),
    );
  }
  const found = findOrgKey(body, 'body') ?? findOrgKey(req.query, 'query');
  if (found) {
    throw BadRequest('The shop comes from the session, not the request.', 'VALIDATION_FAILED', {
      path: found,
    });
  }
  next();
}
