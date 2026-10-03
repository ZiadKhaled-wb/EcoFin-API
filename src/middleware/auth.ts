// server/src/middleware/auth.ts
//
//   authenticate   validates the bearer token with Supabase Auth (server-side, so a revoked
//                  session fails) and puts { userId, email, accessToken, orgId? } on req.auth.
//   dbFor(req)     a fresh Supabase client that runs as the caller (+ x-org-id). The hook for
//                  F05: its org-scope middleware loads the employee through this client.
//   requestMeta    ip / user agent / request id for audit rows and login_attempts.
//
// Loading the employee per request and enforcing org scope is F05; permissions are F06.

import type { Request, Response, NextFunction } from 'express';
import { Uuid } from '@ecotech/contracts';
import {
  createAuthClient,
  supabaseForRequest,
  type DbClient,
  type RequestMeta,
} from '../utils/supabase';
import { asyncHandler } from '../utils/asyncHandler';
import { AppError, BadRequest, ServerError, Unauthorized } from '../utils/errors';
import { logger } from '../utils/logger';
import { decodeJwtPayload } from '../utils/jwt';
import { isAuthClientError } from '../utils/authErrors';

function bearerToken(req: Request): string | undefined {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) return undefined;
  const token = header.slice('Bearer '.length).trim();
  return token || undefined;
}

/** `x-org-id`: absent, or exactly one UUID. Anything else is rejected. */
function requestedOrgId(req: Request): string | undefined {
  const raw = req.headers['x-org-id'];
  if (raw === undefined || raw === '') return undefined;
  if (typeof raw !== 'string' || !Uuid.safeParse(raw).success) {
    throw BadRequest('x-org-id must be a UUID.', 'VALIDATION_FAILED');
  }
  return raw.toLowerCase();
}

/** True when the token's own `exp` has passed. Only used to pick the error code. */
function looksExpired(token: string): boolean {
  const exp = decodeJwtPayload(token)?.exp;
  return typeof exp === 'number' && exp * 1000 <= Date.now();
}

export const authenticate = asyncHandler(
  async (req: Request, _res: Response, next: NextFunction) => {
    const token = bearerToken(req);
    if (!token) throw Unauthorized('Authentication required.', 'UNAUTHORIZED');
    const orgId = requestedOrgId(req);

    // GET /auth/v1/user: GoTrue checks the signature, the expiry AND that the session in the
    // token's session_id still exists, so a logged-out session is refused here.
    const { data, error } = await createAuthClient().auth.getUser(token);
    if (error || !data.user) {
      if (error && !isAuthClientError(error)) {
        // Supabase Auth unreachable: fail closed, but don't tell the client to log in again.
        logger.error({ err: error }, 'authenticate: Supabase Auth call failed');
        throw ServerError('Authentication service unavailable.');
      }
      throw looksExpired(token)
        ? new AppError('Session expired.', 'TOKEN_EXPIRED')
        : new AppError('Invalid session.', 'TOKEN_INVALID');
    }

    req.auth = {
      userId: data.user.id,
      email: data.user.email ?? null,
      accessToken: token,
      ...(orgId !== undefined ? { orgId } : {}),
    };
    req.user = { id: data.user.id, email: data.user.email ?? undefined };
    next();
  },
);

export function requestMeta(req: Request): RequestMeta {
  return { ip: req.ip, userAgent: req.get('user-agent'), requestId: req.requestId };
}

/** A per-request client for the authenticated caller. Throws if `authenticate` did not run. */
export function dbFor(req: Request, orgId: string | undefined = req.auth?.orgId): DbClient {
  if (!req.auth) throw new Error('dbFor() called before authenticate.');
  return supabaseForRequest(req.auth.accessToken, orgId, requestMeta(req));
}
