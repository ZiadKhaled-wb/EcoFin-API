// server/src/types/express.d.ts
//
// Ambient module augmentation for Express's Request. Every middleware and
// controller reads req.employee / req.superAdmin / req.user / req.authToken
// through this declaration — no `(req as any)` anywhere in the codebase.
//
// `authToken` is deliberately kept on the request so downstream middleware
// can build a user-scoped Supabase client without re-parsing the header.

import type { TenantRole } from '../utils/validation';

export interface AuthenticatedUser {
    id: string;
    email?: string | undefined;
    app_metadata?: Record<string, unknown> | undefined;
    user_metadata?: Record<string, unknown> | undefined;
}

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

export interface AuthenticatedSuperAdmin {
    id: string;
    auth_user_id: string;
    email: string;
    full_name: string;
    is_active: boolean;
}

declare global {
    namespace Express {
        interface Request {
            /** Populated by a requestId middleware mounted before the router. */
            requestId: string;
            user?: AuthenticatedUser | undefined;
            /** Raw JWT. Needed to build a user-scoped Supabase client. */
            authToken?: string | undefined;
            /** Tenant user context. Absent for platform super admins. */
            employee?: AuthenticatedEmployee | undefined;
            /** Platform super admin context. Absent for tenant users. */
            superAdmin?: AuthenticatedSuperAdmin | undefined;
        }
    }
}

export {};