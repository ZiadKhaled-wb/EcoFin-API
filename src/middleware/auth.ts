// server/src/middleware/auth.ts
//
// Middleware chain reference:
//
//   authenticate       verify JWT, attach req.user + req.authToken
//   attachEmployee     load the tenant employee row via RLS
//   attachSuperAdmin   load the platform super-admin row if it exists
//   requireTenant      reject if the caller has no employee row
//   requirePasswordChanged  reject if must_change_password is true
//   isSuperAdmin       attachSuperAdmin + reject if not super admin
//   isOwner            require employee.role === 'OWNER'
//   authorizeRole(...) require employee.role ∈ allowed
//   authorizeModule(k) require employee has module/action permission
//
// Load rules:
//   - Every employee/super-admin read goes through supabaseUser(req.authToken)
//     so RLS applies. Never supabaseAdmin here.
//   - is_active is checked in the loaders. Attaching a disabled employee to a
//     request is a bug, not a state.

import type { Request, Response, NextFunction } from 'express';
import { supabaseAnon, supabaseUser } from '../utils/supabase';
import { asyncHandler } from '../utils/asyncHandler';
import { Unauthorized, Forbidden } from '../utils/errors';
import { logger } from '../utils/logger';
import { isValidPermission, type TenantRole } from '../utils/validation';
import type { AuthenticatedSuperAdmin } from '../types/express';

// --------------------------------------------------
// authenticate
// --------------------------------------------------
export const authenticate = asyncHandler(
  async (req: Request, _res: Response, next: NextFunction) => {
    const header = req.headers.authorization;
    if (!header || !header.startsWith('Bearer ')) {
      throw Unauthorized('مطلوب تسجيل الدخول', 'UNAUTHORIZED');
    }
    const token = header.slice('Bearer '.length).trim();
    if (!token) {
      throw Unauthorized('مطلوب تسجيل الدخول', 'UNAUTHORIZED');
    }

    // Verify the JWT with the anon client. Using the service-role client
    // here would work but muddles the "service-role is pre-auth only"
    // rule — keep the distinction clean.
    const { data, error } = await supabaseAnon.auth.getUser(token);
    if (error || !data?.user) {
      throw Unauthorized('جلسة غير صالحة', 'UNAUTHORIZED');
    }

    req.user = {
      id: data.user.id,
      email: data.user.email ?? undefined,
      app_metadata: data.user.app_metadata,
      user_metadata: data.user.user_metadata,
    };
    req.authToken = token;
    next();
  },
);

// --------------------------------------------------
// attachEmployee
// --------------------------------------------------
//
// Loads the caller's employee row through the user-scoped client so RLS is
// the actual gate. Does NOT throw if no row exists — a super admin has no
// employee row, and downstream middleware (requireTenant) decides whether
// that is acceptable for the current route.
export const attachEmployee = asyncHandler(
  async (req: Request, _res: Response, next: NextFunction) => {
    if (!req.user || !req.authToken) {
      throw Unauthorized('مطلوب تسجيل الدخول', 'UNAUTHORIZED');
    }

    const userClient = supabaseUser(req.authToken);
    const { data, error } = await userClient
      .from('employees')
      .select(
        'id, organization_id, auth_id, branch_id, role, permissions, is_active, username, email, must_change_password',
      )
      .eq('auth_id', req.user.id)
      .maybeSingle();

    if (error) {
      logger.error({ err: error, userId: req.user.id }, 'attachEmployee: employee read failed');
      throw Unauthorized('فشل تحميل بيانات المستخدم', 'UNAUTHORIZED');
    }
    if (!data) {
      next();
      return;
    }
    if (!data.is_active) {
      throw Forbidden('هذا الحساب معطل. يرجى التواصل مع الإدارة.', 'ACCOUNT_DISABLED');
    }

    req.employee = {
      id: data.id,
      organization_id: data.organization_id,
      auth_id: req.user.id,
      branch_id: data.branch_id ?? null,
      role: data.role as TenantRole,
      permissions: Array.isArray(data.permissions) ? (data.permissions as string[]) : [],
      is_active: data.is_active,
      username: data.username ?? null,
      email: data.email ?? req.user.email ?? null,
      must_change_password: Boolean(data.must_change_password),
    };
    next();
  },
);

// --------------------------------------------------
// Super-admin loaders
// --------------------------------------------------

async function loadSuperAdmin(req: Request): Promise<AuthenticatedSuperAdmin | undefined> {
  if (!req.user || !req.authToken) return undefined;
  // RLS on super_admins is `is_super_admin()` — a disabled super admin
  // cannot read their own row, so a disabled account is indistinguishable
  // from "not a super admin". Both reject. That is intentional.
  const userClient = supabaseUser(req.authToken);
  const { data, error } = await userClient
    .from('super_admins')
    .select('id, auth_user_id, email, full_name, is_active')
    .eq('auth_user_id', req.user.id)
    .maybeSingle();

  if (error) {
    logger.error({ err: error, userId: req.user.id }, 'loadSuperAdmin: query failed');
    return undefined;
  }
  if (!data || !data.is_active) return undefined;
  return {
    id: data.id,
    auth_user_id: data.auth_user_id,
    email: data.email,
    full_name: data.full_name,
    is_active: data.is_active,
  };
}

/** Soft variant — attaches req.superAdmin if the caller is one, otherwise no-op. */
export const attachSuperAdmin = asyncHandler(
  async (req: Request, _res: Response, next: NextFunction) => {
    req.superAdmin = await loadSuperAdmin(req);
    next();
  },
);

/** Strict variant — rejects unless the caller is an active super admin. */
export const isSuperAdmin = asyncHandler(
  async (req: Request, _res: Response, next: NextFunction) => {
    const sa = await loadSuperAdmin(req);
    if (!sa) {
      throw Forbidden('مرفوض: يتطلب صلاحيات المشرف العام.', 'FORBIDDEN');
    }
    req.superAdmin = sa;
    next();
  },
);

// --------------------------------------------------
// Tenant + password gates
// --------------------------------------------------

/** Rejects if the caller has no employee row (i.e. not a tenant user). */
export const requireTenant = asyncHandler(
  async (req: Request, _res: Response, next: NextFunction) => {
    if (!req.employee) {
      throw Forbidden('هذا الإجراء متاح فقط لحسابات المنشآت.', 'TENANT_SCOPE_REQUIRED');
    }
    next();
  },
);

/**
 * Rejects the request if the employee is still on their temporary password.
 * The only routes that bypass this are the ones that must be callable by
 * such a user: POST /change-password and POST /logout.
 */
export const requirePasswordChanged = asyncHandler(
  async (req: Request, _res: Response, next: NextFunction) => {
    if (req.employee?.must_change_password) {
      throw Forbidden('يجب تغيير كلمة المرور قبل المتابعة.', 'MUST_CHANGE_PASSWORD');
    }
    next();
  },
);

// --------------------------------------------------
// Role + module authorization
// --------------------------------------------------

export const isOwner = asyncHandler(async (req: Request, _res: Response, next: NextFunction) => {
  if (!req.employee) {
    throw Forbidden('تعذر تحديد المؤسسة الخاصة بك.', 'FORBIDDEN');
  }
  if (req.employee.role !== 'OWNER') {
    throw Forbidden('هذه العملية متاحة لمالك المنشأة فقط.', 'FORBIDDEN');
  }
  next();
});

export const authorizeRole = (...allowed: TenantRole[]) =>
  asyncHandler(async (req: Request, _res: Response, next: NextFunction) => {
    if (!req.employee) {
      throw Forbidden('تعذر تحديد المؤسسة الخاصة بك.', 'FORBIDDEN');
    }
    if (!allowed.includes(req.employee.role)) {
      throw Forbidden('هذه الوحدة متاحة للمالك والمشرفين فقط.', 'FORBIDDEN');
    }
    next();
  });

/**
 * Accepts either a module-level key ("pos") or an action-level key
 * ("sales.create"). Module-level passes if the caller has the module
 * itself or any `<module>.*` action.
 *
 * OWNER always passes. No other role does.
 */
export const authorizeModule = (moduleKey: string) =>
  asyncHandler(async (req: Request, _res: Response, next: NextFunction) => {
    if (!isValidPermission(moduleKey)) {
      // Programming error — surface loudly rather than silently deny.
      logger.error({ moduleKey }, 'authorizeModule called with an invalid key');
      throw new Error(`authorizeModule called with an invalid key: ${moduleKey}`);
    }
    if (!req.employee) {
      throw Forbidden('تعذر تحديد المؤسسة الخاصة بك.', 'FORBIDDEN');
    }
    const { role, permissions } = req.employee;
    if (role === 'OWNER') {
      next();
      return;
    }
    const hasAccess = permissions.some((p) => {
      if (p === moduleKey) return true;
      // Module-level key matches any of its actions.
      if (!moduleKey.includes('.') && p.startsWith(`${moduleKey}.`)) return true;
      return false;
    });
    if (!hasAccess) {
      throw Forbidden('ليست لديك صلاحية الوصول لهذه الوحدة.', 'FORBIDDEN');
    }
    next();
  });
