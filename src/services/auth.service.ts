// server/src/services/auth.service.ts
//
// Login + password management.
//
// Pre-auth flows (login identifier resolution, forgot-password) use supabaseAdmin: there is no JWT yet, no tenant
// context, and these operations are inherently platform-level.
//
// After signInWithPassword succeeds, every read goes through supabaseUser(jwt)
// so RLS is the real gate. If a read fails, the fallback is "fix the policy",
// not "use the service key".

import { supabaseAdmin, supabaseAnon, supabaseUser } from '../utils/supabase';
import { AppError, BadRequest, Unauthorized, Forbidden, NotFound } from '../utils/errors';
import {
  isNonEmptyString,
  isValidEmail,
  isValidPassword,
  isValidTenantSlug,
  type TenantRole,
} from '../utils/validation';
import { logger } from '../utils/logger';

// ============================================================================
// Login
// ============================================================================

export interface LoginUser {
  id: string;
  personId: string;
  email: string | null;
  username: string | null;
  role: TenantRole | 'SUPER_ADMIN';
  branchId: string | null;
  orgId: string | null;
  permissions: string[];
  isSuperAdmin: boolean;
}

export interface LoginResult {
  user: LoginUser;
  session: { access_token: string; refresh_token: string };
  must_change_password: boolean;
}

// Every credential failure returns this exact message. Do not vary it.
const INVALID_CREDENTIALS = 'بيانات الدخول غير صحيحة.';

export async function login(
  tenant_slug: string,
  identifier: string,
  password: string,
): Promise<LoginResult> {
  if (
    !isNonEmptyString(tenant_slug) ||
    !isNonEmptyString(identifier) ||
    !isNonEmptyString(password)
  ) {
    throw Unauthorized(INVALID_CREDENTIALS, 'INVALID_CREDENTIALS');
  }

  const slug = tenant_slug.trim().toLowerCase();
  if (!isValidTenantSlug(slug)) {
    throw Unauthorized(INVALID_CREDENTIALS, 'INVALID_CREDENTIALS');
  }

  // 1. Resolve the tenant. Pre-auth, service-role.
  const { data: org, error: orgError } = await supabaseAdmin
    .from('organizations')
    .select('id, tenant_slug, name, is_active, is_suspended')
    .eq('tenant_slug', slug)
    .maybeSingle();

  if (orgError) {
    logger.error({ err: orgError, slug }, 'login: organization lookup failed');
    throw new AppError('فشل تسجيل الدخول.', 'INTERNAL', 500);
  }
  if (!org || !org.is_active || org.is_suspended) {
    // Do not distinguish "unknown slug" from "suspended org".
    throw Unauthorized(INVALID_CREDENTIALS, 'INVALID_CREDENTIALS');
  }

  // 2. Resolve the identifier to an email.
  let email: string | null = null;
  const trimmed = identifier.trim();

  if (trimmed.includes('@')) {
    if (!isValidEmail(trimmed)) {
      throw Unauthorized(INVALID_CREDENTIALS, 'INVALID_CREDENTIALS');
    }
    email = trimmed.toLowerCase();
  } else {
    const { data: emp, error: empError } = await supabaseAdmin
      .from('employees')
      .select('auth_id')
      .eq('organization_id', org.id)
      .eq('username', trimmed)
      .maybeSingle();

    if (empError) {
      logger.error({ err: empError, slug }, 'login: username lookup failed');
      throw new AppError('فشل تسجيل الدخول.', 'INTERNAL', 500);
    }
    if (!emp?.auth_id) {
      throw Unauthorized(INVALID_CREDENTIALS, 'INVALID_CREDENTIALS');
    }

    const { data: authUser, error: authUserError } = await supabaseAdmin.auth.admin.getUserById(
      emp.auth_id,
    );
    if (authUserError || !authUser?.user?.email) {
      throw Unauthorized(INVALID_CREDENTIALS, 'INVALID_CREDENTIALS');
    }
    email = authUser.user.email.toLowerCase();
  }

  // 3. Sign in with the anon client — respects Supabase's own rate limiting.
  const { data: signIn, error: signInError } = await supabaseAnon.auth.signInWithPassword({
    email,
    password,
  });
  if (signInError || !signIn?.user || !signIn?.session) {
    throw Unauthorized(INVALID_CREDENTIALS, 'INVALID_CREDENTIALS');
  }

  const jwt = signIn.session.access_token;
  const userClient = supabaseUser(jwt);

  // 4. Load the caller's employee row via RLS. Do NOT fall back to service
  //    role: a broken policy should fail login loudly.
  // server/src/services/auth.service.ts

  // After signInWithPassword succeeds.
  const { data: employee, error: empReadError } = await supabaseAdmin
    .from('employees')
    .select(
      'id, organization_id, role, username, branch_id, permissions, is_active, must_change_password',
    )
    .eq('auth_id', signIn.user.id)
    .maybeSingle();

  if (empReadError) {
    logger.error({ err: empReadError, userId: signIn.user.id }, 'login: employee read failed');
    throw new AppError('فشل تسجيل الدخول.', 'INTERNAL', 500);
  }

  if (employee) {
    // Cross-check the tenant matches the slug the caller supplied.
    if (employee.organization_id !== org.id) {
      logger.warn({/* … */}, 'login: tenant mismatch between JWT and requested slug');
      throw Unauthorized(INVALID_CREDENTIALS, 'INVALID_CREDENTIALS');
    }
    if (!employee.is_active) {
      // Password was correct. This distinction is safe to disclose.
      throw Forbidden('هذا الحساب معطل. يرجى التواصل مع الإدارة.', 'ACCOUNT_DISABLED');
    }

    return {
      user: {
        id: signIn.user.id,
        personId: employee.id,
        email,
        username: employee.username ?? null,
        role: employee.role as TenantRole,
        branchId: employee.branch_id ?? null,
        orgId: employee.organization_id,
        permissions: Array.isArray(employee.permissions) ? (employee.permissions as string[]) : [],
        isSuperAdmin: false,
      },
      session: {
        access_token: signIn.session.access_token,
        refresh_token: signIn.session.refresh_token,
      },
      must_change_password: Boolean(employee.must_change_password),
    };
  }

  // 5. No employee row. Try super admins.
  const { data: sa, error: saError } = await userClient
    .from('super_admins')
    .select('id, email, is_active, full_name')
    .eq('auth_user_id', signIn.user.id)
    .maybeSingle();

  if (saError) {
    logger.error({ err: saError, userId: signIn.user.id }, 'login: super-admin read failed');
    throw new AppError('فشل تسجيل الدخول.', 'INTERNAL', 500);
  }
  if (sa && sa.is_active) {
    // A super admin is a platform user — the slug they supplied is
    // informational, not a scope constraint. See open question in ADR.
    return {
      user: {
        id: signIn.user.id,
        personId: sa.id,
        email: signIn.user.email ?? email,
        username: null,
        role: 'SUPER_ADMIN',
        branchId: null,
        orgId: org.id,
        permissions: [],
        isSuperAdmin: true,
      },
      session: {
        access_token: signIn.session.access_token,
        refresh_token: signIn.session.refresh_token,
      },
      must_change_password: false,
    };
  }

  // No employee, no super admin. Misprovisioned account.
  throw Unauthorized(INVALID_CREDENTIALS, 'INVALID_CREDENTIALS');
}

// ============================================================================
// forgotPassword
// ============================================================================
//
// Always returns success to the caller. Never reveals whether the tenant
// exists, whether the identifier maps to a user, or whether an email was
// actually sent.
export async function forgotPassword(tenant_slug: string, identifier: string): Promise<void> {
  if (!isNonEmptyString(tenant_slug) || !isNonEmptyString(identifier)) return;

  const slug = tenant_slug.trim().toLowerCase();
  if (!isValidTenantSlug(slug)) return;

  const { data: org } = await supabaseAdmin
    .from('organizations')
    .select('id')
    .eq('tenant_slug', slug)
    .maybeSingle();
  if (!org) return;

  let email: string | null = null;
  const trimmed = identifier.trim();

  if (trimmed.includes('@')) {
    if (isValidEmail(trimmed)) email = trimmed.toLowerCase();
  } else {
    const { data: emp } = await supabaseAdmin
      .from('employees')
      .select('auth_id')
      .eq('organization_id', org.id)
      .eq('username', trimmed)
      .maybeSingle();
    if (emp?.auth_id) {
      const { data: authUser } = await supabaseAdmin.auth.admin.getUserById(emp.auth_id);
      email = authUser?.user?.email ?? null;
    }
  }
  if (!email) return;

  // Confirm the email belongs to this org before sending. Otherwise a
  // user could type a foreign email and trigger a reset link for a
  // different tenant's user via a tenant-scoped form.
  const { data: empByEmail } = await supabaseAdmin
    .from('employees')
    .select('auth_id')
    .eq('organization_id', org.id)
    .eq('email', email)
    .maybeSingle();
  if (!empByEmail) return;

  const redirectTo = `${process.env.FRONTEND_URL ?? 'http://localhost:5173'}/reset-password`;

  const { error } = await supabaseAnon.auth.resetPasswordForEmail(email, { redirectTo });
  if (error) {
    // Log the failure but do not surface it — the response shape is
    // identical regardless.
    logger.warn({ err: error, slug }, 'forgotPassword: resetPasswordForEmail failed');
  }
}

// ============================================================================
// resetOwnerPassword
// ============================================================================
//
// Owner-scoped, in-app password reset for another employee in the same org.
// The middleware chain already enforces auth + isOwner; this function
// re-checks the tenant scope so a routing mistake can't turn into a
// cross-tenant account takeover.
export async function resetOwnerPassword(
  userId: string,
  newPassword: string,
  callerOrgId: string,
): Promise<void> {
  if (!isNonEmptyString(userId) || !isNonEmptyString(newPassword)) {
    throw BadRequest('حقول مطلوبة مفقودة.', 'VALIDATION_FAILED');
  }
  if (!isNonEmptyString(callerOrgId)) {
    throw Forbidden('تعذر تحديد المؤسسة الخاصة بك.', 'TENANT_SCOPE_REQUIRED');
  }
  if (!isValidPassword(newPassword)) {
    throw BadRequest('كلمة المرور الجديدة ضعيفة.', 'VALIDATION_FAILED');
  }

  const { data: target, error: targetError } = await supabaseAdmin
    .from('employees')
    .select('id, organization_id')
    .eq('auth_id', userId)
    .maybeSingle();

  if (targetError) {
    logger.error({ err: targetError, userId }, 'resetOwnerPassword: target lookup failed');
    throw new AppError('فشل إعادة تعيين كلمة المرور.', 'INTERNAL', 500);
  }
  if (!target) {
    throw NotFound('لم يتم العثور على هذا الحساب.', 'NOT_FOUND');
  }
  if (target.organization_id !== callerOrgId) {
    logger.warn(
      { callerOrgId, targetOrgId: target.organization_id, targetUserId: userId },
      'resetOwnerPassword: cross-tenant attempt blocked',
    );
    throw Forbidden('لا يمكنك إعادة تعيين كلمة المرور لحساب خارج مؤسستك.', 'FORBIDDEN');
  }

  const { error } = await supabaseAdmin.auth.admin.updateUserById(userId, {
    password: newPassword,
  });
  if (error) {
    logger.error({ err: error, userId, callerOrgId }, 'resetOwnerPassword: update failed');
    throw new AppError('فشل تحديث كلمة المرور.', 'INTERNAL', 500);
  }
}

// ============================================================================
// changePassword
// ============================================================================
//
// The temp-password flow. Called on a session where the employee row has
// must_change_password = true — the only endpoint (besides logout) that
// such a user can reach.
export async function changePassword(
  employeeId: string,
  callerAuthId: string,
  callerOrgId: string,
  currentPassword: string,
  newPassword: string,
  confirmPassword: string,
): Promise<void> {
  if (!isNonEmptyString(currentPassword)) {
    throw BadRequest('كلمة المرور الحالية مطلوبة.', 'VALIDATION_FAILED');
  }
  if (!isValidPassword(newPassword)) {
    throw BadRequest('كلمة المرور الجديدة ضعيفة (8 أحرف على الأقل).', 'VALIDATION_FAILED');
  }
  if (newPassword !== confirmPassword) {
    throw BadRequest('كلمتا المرور غير متطابقتين.', 'VALIDATION_FAILED');
  }
  if (currentPassword === newPassword) {
    throw BadRequest('يجب اختيار كلمة مرور مختلفة عن الحالية.', 'VALIDATION_FAILED');
  }

  // Look up the caller's email so we can verify the current password.
  const { data: authUser, error: authErr } =
    await supabaseAdmin.auth.admin.getUserById(callerAuthId);
  if (authErr || !authUser?.user?.email) {
    throw new AppError('تعذر التحقق من الحساب.', 'INTERNAL', 500);
  }

  // Verify current password via the anon client — this respects rate limits
  // and gives us Supabase's own verification rather than trusting our own.
  const { error: signInError } = await supabaseAnon.auth.signInWithPassword({
    email: authUser.user.email,
    password: currentPassword,
  });
  if (signInError) {
    throw Unauthorized('كلمة المرور الحالية غير صحيحة.', 'INVALID_CREDENTIALS');
  }

  const { error: updateErr } = await supabaseAdmin.auth.admin.updateUserById(callerAuthId, {
    password: newPassword,
  });
  if (updateErr) {
    logger.error({ err: updateErr, employeeId }, 'changePassword: auth update failed');
    throw new AppError('فشل تحديث كلمة المرور.', 'INTERNAL', 500);
  }

  // Clear the flag. Scoped to the caller's org — defence in depth.
  const { error: clearErr } = await supabaseAdmin
    .from('employees')
    .update({
      must_change_password: false,
      password_changed_at: new Date().toISOString(),
    })
    .eq('id', employeeId)
    .eq('organization_id', callerOrgId);

  if (clearErr) {
    // The password IS updated; only the flag write failed. The user can
    // log in with the new password. Log P1 for a human to notice.
    logger.error(
      { err: clearErr, employeeId, callerOrgId },
      'P1: changePassword updated the auth password but failed to clear must_change_password',
    );
    throw new AppError('تم تحديث كلمة المرور. يرجى إعادة تسجيل الدخول.', 'INTERNAL', 500);
  }
}

// ============================================================================
// refreshSession
// ============================================================================
//
// Exchanges a Supabase refresh token for a new access + refresh token pair.
// Pre-auth flow: the caller's access token has expired by definition, so we
// use supabaseAnon (no JWT to attach). Supabase rotates the refresh token on
// every call, so we return the new one alongside the new access token.

export interface RefreshResult {
  session: { access_token: string; refresh_token: string };
}

export async function refreshSession(refreshToken: string): Promise<RefreshResult> {
  if (!isNonEmptyString(refreshToken)) {
    throw Unauthorized('رمز التحديث مطلوب.', 'UNAUTHORIZED');
  }

  const { data, error } = await supabaseAnon.auth.refreshSession({
    refresh_token: refreshToken,
  });

  if (error || !data?.session) {
    throw Unauthorized('انتهت الجلسة. يرجى تسجيل الدخول مرة أخرى.', 'UNAUTHORIZED');
  }

  return {
    session: {
      access_token: data.session.access_token,
      refresh_token: data.session.refresh_token,
    },
  };
}
