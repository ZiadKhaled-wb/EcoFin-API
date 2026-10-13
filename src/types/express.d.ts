// server/src/types/express.d.ts
//
// Ambient module augmentation for Express's Request. Every middleware and
// controller reads req.auth / req.user / req.ctx through this declaration —
// no `(req as any)` anywhere in the codebase.

import type { RequestContext } from '../middleware/requestContext';
import type { RequestDevice } from '../middleware/deviceContext';

export interface AuthenticatedUser {
  id: string;
  email?: string | undefined;
}

/**
 * Set by `authenticate` (F04) after Supabase Auth validated the token server-side.
 * `accessToken` is kept so the request can build its own Supabase client (supabaseForRequest).
 * `orgId` is the `x-org-id` header, only checked to be a UUID: the database decides whether
 * the caller belongs to that shop.
 */
export interface RequestAuth {
  userId: string;
  email: string | null;
  accessToken: string;
  orgId?: string | undefined;
}

declare global {
  namespace Express {
    interface Request {
      /** Populated by a requestId middleware mounted before the router. */
      requestId: string;
      /** Session of the caller (F04 `authenticate`). */
      auth?: RequestAuth | undefined;
      /** Same user, kept for the logger and error handler. */
      user?: AuthenticatedUser | undefined;
      /** Tenant context of the caller (F05 loadRequestContext); read it with getCtx(req). */
      ctx?: RequestContext | undefined;
      /** The paired POS device of this request (O03 deviceContext); absent without a device token. */
      device?: RequestDevice | undefined;
    }
  }
}

export {};
