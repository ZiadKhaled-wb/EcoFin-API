// server/src/types/express.d.ts
//
// Ambient module augmentation for Express's Request. Every middleware and
// controller reads req.auth / req.user / req.employee through this declaration —
// no `(req as any)` anywhere in the codebase.

import type { TenantRole } from '../utils/validation';

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

/** Tenant employee context. Loaded per request by the F05 org-scope middleware (not built yet). */
export interface AuthenticatedEmployee {
  id: string;
  organization_id: string;
  auth_id: string;
  branch_id: string | null;
  role: TenantRole;
  permissions: string[];
  is_active: boolean;
  username: string | null;
  email: string | null;
  must_change_password: boolean;
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
      /** Tenant user context (F05). */
      employee?: AuthenticatedEmployee | undefined;
    }
  }
}

export {};
