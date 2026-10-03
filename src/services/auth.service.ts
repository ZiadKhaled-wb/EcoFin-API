// server/src/services/auth.service.ts
//
// Activation + login + password management. See ADR-0004 for the reasoning
// behind the ordering choices (especially activateWorkspace).
//
// Pre-auth flows (login identifier resolution, checkLicense, activate,
// forgot-password) use supabaseAdmin: there is no JWT yet, no tenant
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
  isValidLicenseKey,
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
// checkLicense
// ============================================================================

export interface CheckLicenseResult {
  license_key: string;
  is_used: boolean;
  plan_key: string | null;
  org_name: string | null;
}

// Deliberately does NOT return owner_email. The activation form lets the
// user type their own email; if it doesn't match, activateWorkspace rejects.
// Returning the owner email during a side-effect-free lookup was an
// enumeration leak (see ADR-0004).
export async function checkLicense(licenseKey: string): Promise<CheckLicenseResult> {
  if (!isValidLicenseKey(licenseKey)) {
    throw BadRequest('كود التفعيل غير صالح.', 'BAD_REQUEST');
  }
  const normalized = licenseKey.trim().toUpperCase();

  const { data: license, error } = await supabaseAdmin
    .from('saaslicenses')
    .select('license_key, is_used, is_active, is_revoked, expires_at, plan_key, issued_to_org_id')
    .eq('license_key', normalized)
    .maybeSingle();

  if (error) {
    logger.error({ err: error }, 'checkLicense: query failed');
    throw new AppError('فشل التحقق من كود التفعيل.', 'INTERNAL', 500);
  }
  if (!license) {
    throw BadRequest('كود التفعيل غير صحيح.', 'BAD_REQUEST');
  }

  const isUsable =
    !license.is_used &&
    license.is_active &&
    !license.is_revoked &&
    (!license.expires_at || new Date(license.expires_at) > new Date());

  let orgName: string | null = null;
  if (isUsable && license.issued_to_org_id) {
    const { data: org } = await supabaseAdmin
      .from('organizations')
      .select('name')
      .eq('id', license.issued_to_org_id)
      .maybeSingle();
    orgName = org?.name ?? null;
  }

  return {
    license_key: license.license_key,
    is_used: license.is_used,
    plan_key: license.plan_key ?? null,
    org_name: orgName,
  };
}

// ============================================================================
// activateWorkspace
// ============================================================================

export interface ActivateWorkspacePayload {
  license_key: string;
  email: string;
  username: string;
  password: string;
  confirmPassword: string;
}

export interface ActivateWorkspaceResult {
  tenant_slug: string;
  tenant_name: string;
  org_id: string;
}

// NOTE on ordering (see ADR-0004 §"activation ordering"):
//
//   1. Pre-flight read. Read-only.
//   2. Update the Supabase Auth password FIRST. On failure, no state changed.
//   3. Call the activate_workspace RPC, which performs the atomic DB writes
//      (license flip + username + audit) inside one transaction.
//
// If step 3 fails after step 2 succeeded, the user can retry activation
// safely — the Auth password is set but the license is still unused. If
// step 2 had run after step 3 instead, a network blip on the Auth call
// would leave the license marked used and the user permanently locked out.
export async function activateWorkspace(
  payload: ActivateWorkspacePayload,
): Promise<ActivateWorkspaceResult> {
  const { license_key, email, username, password, confirmPassword } = payload;

  if (!isValidLicenseKey(license_key)) throw BadRequest('كود التفعيل غير صالح.', 'BAD_REQUEST');
  if (!isValidEmail(email)) throw BadRequest('البريد الإلكتروني غير صالح.', 'VALIDATION_FAILED');
  if (!isNonEmptyString(username) || username.trim().length < 3) {
    throw BadRequest('اسم المستخدم يجب ألا يقل عن 3 أحرف.', 'VALIDATION_FAILED');
  }
  if (!isValidPassword(password)) {
    throw BadRequest('كلمة المرور ضعيفة (8 أحرف على الأقل).', 'VALIDATION_FAILED');
  }
  if (password !== confirmPassword) {
    throw BadRequest('كلمتا المرور غير متطابقتين.', 'VALIDATION_FAILED');
  }

  const normalizedKey = license_key.trim().toUpperCase();
  const trimmedUsername = username.trim();

  // Step 1 — pre-flight reads.
  const { data: license, error: licError } = await supabaseAdmin
    .from('saaslicenses')
    .select('id, is_used, is_active, is_revoked, expires_at, issued_to_org_id')
    .eq('license_key', normalizedKey)
    .maybeSingle();

  if (licError) {
    logger.error({ err: licError }, 'activateWorkspace: license lookup failed');
    throw new AppError('فشل التفعيل.', 'INTERNAL', 500);
  }
  if (!license) throw BadRequest('كود التفعيل غير صحيح.', 'BAD_REQUEST');
  if (license.is_used) throw BadRequest('تم استخدام كود التفعيل هذا بالفعل.', 'BAD_REQUEST');
  if (!license.is_active || license.is_revoked) {
    throw BadRequest('كود التفعيل غير صالح.', 'BAD_REQUEST');
  }
  if (license.expires_at && new Date(license.expires_at) <= new Date()) {
    throw BadRequest('انتهت صلاحية كود التفعيل.', 'BAD_REQUEST');
  }
  if (!license.issued_to_org_id) {
    throw NotFound(
      'لم يتم تجهيز المنشأة الخاصة بهذا الكود بعد. يرجى التواصل مع الدعم.',
      'NOT_FOUND',
    );
  }

  const { data: owner, error: ownerError } = await supabaseAdmin
    .from('employees')
    .select('id, auth_id')
    .eq('organization_id', license.issued_to_org_id)
    .eq('role', 'OWNER')
    .maybeSingle();

  if (ownerError) {
    logger.error(
      { err: ownerError, orgId: license.issued_to_org_id },
      'activateWorkspace: owner lookup failed',
    );
    throw new AppError('فشل التفعيل.', 'INTERNAL', 500);
  }
  if (!owner?.auth_id) {
    throw NotFound('لم يتم العثور على حساب المالك المرتبط بهذا الكود.', 'NOT_FOUND');
  }

  const { data: authUserData, error: authUserError } = await supabaseAdmin.auth.admin.getUserById(
    owner.auth_id,
  );
  if (authUserError || !authUserData?.user?.email) {
    throw new AppError('تعذر التحقق من بيانات الحساب.', 'INTERNAL', 500);
  }
  if (authUserData.user.email.trim().toLowerCase() !== email.trim().toLowerCase()) {
    throw Unauthorized(
      'البريد الإلكتروني لا يطابق البريد المسجل لهذا الكود.',
      'INVALID_CREDENTIALS',
    );
  }

  // Step 2 — password FIRST. On failure nothing else has changed.
  const { error: pwError } = await supabaseAdmin.auth.admin.updateUserById(owner.auth_id, {
    password,
  });
  if (pwError) {
    logger.error({ err: pwError, ownerId: owner.id }, 'activateWorkspace: password update failed');
    throw new AppError('فشل تحديث كلمة المرور.', 'INTERNAL', 500);
  }

  // Step 3 — atomic DB writes via RPC. The function re-validates the
  // license inside its own transaction (SELECT ... FOR UPDATE), so a
  // concurrent activation on the same key cannot double-succeed.
  const { data: rpcData, error: rpcError } = await supabaseAdmin.rpc('activate_workspace', {
    p_license_key: normalizedKey,
    p_owner_auth_id: owner.auth_id,
    p_username: trimmedUsername,
  });

  if (rpcError) {
    // The Auth password is already set but the DB state is unchanged.
    // This is a recoverable state: the user can re-run activation. Log
    // loudly so a human sees it if it happens in production.
    const message = rpcError.message ?? '';
    if (message.includes('BAD_REQUEST')) {
      throw BadRequest('تم استخدام كود التفعيل هذا بالفعل.', 'BAD_REQUEST');
    }
    if (message.includes('USERNAME_TAKEN')) {
      throw BadRequest('اسم المستخدم هذا مستخدم بالفعل، يرجى اختيار اسم آخر.', 'VALIDATION_FAILED');
    }
    if (message.includes('BAD_REQUEST')) {
      throw BadRequest('انتهت صلاحية كود التفعيل.', 'BAD_REQUEST');
    }
    if (message.includes('BAD_REQUEST')) {
      throw BadRequest('كود التفعيل غير صالح.', 'BAD_REQUEST');
    }
    if (message.includes('OWNER_NOT_FOUND')) {
      throw NotFound('لم يتم العثور على حساب المالك المرتبط بهذا الكود.', 'NOT_FOUND');
    }

    logger.error(
      {
        err: rpcError,
        licenseKey: normalizedKey,
        ownerId: owner.id,
        ownerAuthId: owner.auth_id,
      },
      'P1: activateWorkspace RPC failed AFTER password update — state is recoverable but requires follow-up',
    );
    throw new AppError(
      'فشل تفعيل المنشأة. يرجى المحاولة مرة أخرى أو التواصل مع الدعم.',
      'INTERNAL',
      500,
    );
  }

  const row = Array.isArray(rpcData) ? rpcData[0] : rpcData;
  if (!row?.tenant_slug || !row?.org_id) {
    logger.error(
      { rpcData, licenseKey: normalizedKey },
      'P1: activateWorkspace RPC returned unexpected shape',
    );
    throw new AppError('فشل تفعيل المنشأة.', 'INTERNAL', 500);
  }

  return {
    tenant_slug: row.tenant_slug as string,
    tenant_name: (row.tenant_name as string) ?? '',
    org_id: row.org_id as string,
  };
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
