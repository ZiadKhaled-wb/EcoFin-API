// server/src/services/auth.service.ts
//
// F04 auth and sessions. Request and response shapes come from @ecotech/contracts (auth module).
//
//   * Supabase Auth calls use a NEW anon client each time (createAuthClient), so no client ever
//     keeps a user session between requests.
//   * Service-role steps (username -> email, membership checks, login_attempts) live in
//     auth.admin.ts only (D14).
//   * Everything that runs as the user goes through supabaseForRequest(<JWT>, <x-org-id>), and
//     every write is a SECURITY DEFINER function (migration 20261003060000_f04_auth.sql).
//   * Client-facing messages are generic; the client localises from the error code.

import type { Session } from '@supabase/supabase-js';
import type {
  AuthChangePasswordBody,
  AuthForgotPasswordBody,
  AuthLoginBody,
  AuthLoginResponse,
  AuthMeResponse,
  AuthRefreshResponse,
  AuthResetPasswordBody,
  AuthSelectShopResponse,
  AuthSession,
  AuthUser,
  ShopMembership,
} from '@ecotech/contracts';
import {
  createAuthClient,
  supabaseForRequest,
  updatePasswordWithToken,
  type DbClient,
  type RequestMeta,
} from '../utils/supabase';
import { AppError, BadRequest, ServerError, Unauthorized, mapDbError } from '../utils/errors';
import { getEnv } from '../utils/env';
import { logger } from '../utils/logger';
import { decodeJwtPayload, looksLikeJwt } from '../utils/jwt';
import { authErrorStatus, isAuthClientError } from '../utils/authErrors';
import {
  countRecentFailures,
  findLoginEmailByUsername,
  loadMemberships,
  recordLoginAttempt,
  type MembershipRow,
} from './auth.admin';
import type { RequestAuth } from '../types/express';

// ============================================================================
// Helpers
// ============================================================================

const invalidCredentials = () => Unauthorized('Invalid credentials.', 'INVALID_CREDENTIALS');
const tokenInvalid = () => new AppError('Invalid or expired token.', 'TOKEN_INVALID');

function toAuthSession(session: Session): AuthSession {
  const expiresAtSeconds =
    session.expires_at ?? Math.floor(Date.now() / 1000) + (session.expires_in ?? 0);
  return {
    accessToken: session.access_token,
    refreshToken: session.refresh_token,
    expiresAt: new Date(expiresAtSeconds * 1000).toISOString(),
  };
}

/** Today's date (YYYY-MM-DD) in the shop's timezone, like app.org_today(). */
export function todayIn(timezone: string, now: Date = new Date()): string {
  try {
    return new Intl.DateTimeFormat('en-CA', { timeZone: timezone }).format(now);
  } catch {
    return new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Cairo' }).format(now);
  }
}

/** P05: expired = subscription_end < org_today. No end date = not expired. */
function subscriptionExpired(row: MembershipRow, now: Date): boolean {
  return row.subscriptionEnd !== null && row.subscriptionEnd < todayIn(row.timezone, now);
}

/** Revokes one session (scope local) or all of the user's sessions. Never throws. */
async function revokeSession(
  accessToken: string,
  scope: 'local' | 'global' | 'others',
): Promise<boolean> {
  try {
    const { error } = await createAuthClient().auth.admin.signOut(accessToken, scope);
    if (error) {
      logger.error({ err: error, scope }, 'auth: session revocation failed');
      return false;
    }
    return true;
  } catch (err) {
    logger.error({ err, scope }, 'auth: session revocation failed');
    return false;
  }
}

/** Throws the contract error for a database error (mapped code or generic INTERNAL). */
function dbError(err: unknown, what: string): AppError {
  const mapped = mapDbError(err);
  if (mapped) return mapped;
  logger.error({ err }, `auth: ${what} failed`);
  return ServerError('Request failed.');
}

async function myShops(db: DbClient): Promise<ShopMembership[]> {
  const { data, error } = await db.rpc('my_shops');
  if (error) throw dbError(error, 'my_shops');
  return (data ?? []).map((row) => ({
    orgId: row.org_id,
    orgName: row.org_name,
    tenantSlug: row.tenant_slug,
    role: row.role,
  }));
}

async function lockoutCheck(
  identifier: string,
  tenantSlug: string | null,
  attempt: LoginAttemptBase,
) {
  const env = getEnv();
  const failures = await countRecentFailures(identifier, tenantSlug, env.LOGIN_WINDOW_MINUTES);
  if (failures >= env.LOGIN_MAX_FAILURES) {
    await recordLoginAttempt({ ...attempt, success: false });
    throw new AppError(
      'Too many failed login attempts. Try again later.',
      'TOO_MANY_LOGIN_ATTEMPTS',
    );
  }
}

interface LoginAttemptBase {
  identifier: string;
  tenantSlug: string | null;
  ip?: string | undefined;
  userAgent?: string | undefined;
}

/** Signs in with a fresh client. Wrong password (or any 4xx from Auth) -> null. */
async function signIn(email: string, password: string): Promise<Session | null> {
  const { data, error } = await createAuthClient().auth.signInWithPassword({ email, password });
  if (error) {
    if (!isAuthClientError(error)) {
      logger.error({ err: error }, 'auth: Supabase Auth sign-in call failed');
      throw ServerError('Login failed.');
    }
    if (authErrorStatus(error) === 429) {
      throw new AppError('Too many requests. Try again later.', 'TOO_MANY_REQUESTS');
    }
    return null;
  }
  return data.session ?? null;
}

// ============================================================================
// Login
// ============================================================================

interface ShopDecision {
  shops: ShopMembership[];
  activeShop: ShopMembership | null;
  mustChangePassword: boolean;
}

/**
 * Picks the shops this login may use and refuses the login when none is usable:
 *   ACCOUNT_DISABLED      every candidate employee row is inactive or archived
 *   SHOP_INACTIVE         the shop status is anything but 'active' (suspended, expired, closed)
 *   SUBSCRIPTION_EXPIRED  subscription_end is before today in the shop's timezone (P05)
 * `targetSlug` (username login, or email + tenantSlug) limits the decision to that shop.
 */
async function decideShops(
  userId: string,
  accessToken: string,
  targetSlug: string | null,
  meta: RequestMeta,
): Promise<ShopDecision> {
  const rows = await loadMemberships(userId);

  if (rows.length === 0) {
    // Platform super admin (no employee rows): self-read of super_admins with the user's JWT.
    const db = supabaseForRequest(accessToken, undefined, meta);
    const { data, error } = await db
      .from('super_admins')
      .select('is_active')
      .eq('auth_user_id', userId)
      .maybeSingle();
    if (error) throw dbError(error, 'super admin lookup');
    if (!data) throw invalidCredentials();
    if (!data.is_active) throw new AppError('Account disabled.', 'ACCOUNT_DISABLED');
    return { shops: [], activeShop: null, mustChangePassword: false };
  }

  const candidates = targetSlug ? rows.filter((r) => r.tenantSlug === targetSlug) : rows;
  if (candidates.length === 0) throw invalidCredentials();

  const active = candidates.filter((r) => r.isActive && !r.archived);
  if (active.length === 0) throw new AppError('Account disabled.', 'ACCOUNT_DISABLED');
  const open = active.filter((r) => r.orgStatus === 'active');
  if (open.length === 0) throw new AppError('Shop inactive.', 'SHOP_INACTIVE');
  const now = new Date();
  const usable = open.filter((r) => !subscriptionExpired(r, now));
  if (usable.length === 0) throw new AppError('Subscription expired.', 'SUBSCRIPTION_EXPIRED');

  // D14: the list itself comes from my_shops() with the user's JWT.
  const listed = await myShops(supabaseForRequest(accessToken, undefined, meta));
  const usableIds = new Set(usable.map((r) => r.orgId));
  const shops = listed.filter((s) => usableIds.has(s.orgId));
  if (shops.length === 0) {
    logger.error({ userId }, 'login: membership check and my_shops() disagree');
    throw ServerError('Login failed.');
  }

  const activeShop = shops.length === 1 ? (shops[0] ?? null) : null;
  const flagRows = activeShop ? usable.filter((r) => r.orgId === activeShop.orgId) : usable;
  return {
    shops,
    activeShop,
    mustChangePassword: flagRows.some((r) => r.mustChangePassword),
  };
}

async function recordLogin(accessToken: string, orgId: string, meta: RequestMeta): Promise<void> {
  const { error } = await supabaseForRequest(accessToken, orgId, meta).rpc('auth_record_login');
  if (error) throw dbError(error, 'auth_record_login');
}

export async function login(body: AuthLoginBody, meta: RequestMeta): Promise<AuthLoginResponse> {
  const identifier = body.identifier.trim().toLowerCase();
  const isEmail = identifier.includes('@');
  const tenantSlug = body.tenantSlug ?? null;
  const attempt: LoginAttemptBase = {
    identifier,
    tenantSlug,
    ip: meta.ip,
    userAgent: meta.userAgent,
  };

  // D17: refuse before Supabase Auth is called.
  await lockoutCheck(identifier, isEmail ? null : tenantSlug, attempt);

  const failed = async () => {
    await recordLoginAttempt({ ...attempt, success: false });
    return invalidCredentials();
  };

  // Unknown slug, unknown username and wrong password all end in the same INVALID_CREDENTIALS.
  const email = isEmail
    ? identifier
    : tenantSlug
      ? await findLoginEmailByUsername(tenantSlug, identifier)
      : null;
  if (!email) throw await failed();

  const session = await signIn(email, body.password);
  if (!session?.user) throw await failed();

  // Password is right. Any refusal from here on revokes the session that was just created.
  try {
    const decision = await decideShops(session.user.id, session.access_token, tenantSlug, meta);
    if (decision.activeShop) {
      await recordLogin(session.access_token, decision.activeShop.orgId, meta);
    }
    await recordLoginAttempt({ ...attempt, success: true });

    const user: AuthUser = { id: session.user.id, email: session.user.email ?? null };
    return {
      ...toAuthSession(session),
      user,
      mustChangePassword: decision.mustChangePassword,
      // With a target shop, only that shop is returned so the client knows which one is active.
      shops: decision.activeShop ? [decision.activeShop] : decision.shops,
      requiresShopSelection: decision.activeShop === null && decision.shops.length > 1,
    };
  } catch (err) {
    await revokeSession(session.access_token, 'local');
    if (err instanceof AppError && err.code === 'INVALID_CREDENTIALS') {
      throw await failed();
    }
    // Not a credential failure: record it without counting against the lockout twice.
    await recordLoginAttempt({ ...attempt, success: false }).catch(() => undefined);
    throw err;
  }
}

// ============================================================================
// Select shop (D23). Works with a multi-shop login token and no x-org-id: the body's orgId is
// the choice, checked against my_shops(). The client keeps its tokens and sends x-org-id.
// ============================================================================

export async function selectShop(
  auth: RequestAuth,
  orgId: string,
  meta: RequestMeta,
): Promise<AuthSelectShopResponse> {
  const shops = await myShops(supabaseForRequest(auth.accessToken, undefined, meta));
  const shop = shops.find((s) => s.orgId === orgId.toLowerCase());
  if (!shop) throw new AppError('Shop not allowed.', 'SHOP_NOT_ALLOWED');
  await recordLogin(auth.accessToken, shop.orgId, meta);
  return { user: { id: auth.userId, email: auth.email }, shop };
}

// ============================================================================
// Refresh
// ============================================================================

export async function refresh(refreshToken: string): Promise<AuthRefreshResponse> {
  const { data, error } = await createAuthClient().auth.refreshSession({
    refresh_token: refreshToken,
  });
  if (error && !isAuthClientError(error)) {
    logger.error({ err: error }, 'refresh: Supabase Auth call failed');
    throw ServerError('Refresh failed.');
  }
  if (error || !data.session) throw tokenInvalid();
  return toAuthSession(data.session);
}

// ============================================================================
// Logout
// ============================================================================

const NO_SHOP_SESSION = new Set(['SHOP_SELECTION_REQUIRED', 'NOT_AN_EMPLOYEE', 'SHOP_NOT_ALLOWED']);

export async function logout(auth: RequestAuth, meta: RequestMeta): Promise<void> {
  // Audit first (needs the still-valid token), then revoke. Logout always revokes, even when
  // the audit can't be written (no active shop, e.g. a multi-shop login before selection).
  const { error } = await supabaseForRequest(auth.accessToken, auth.orgId, meta).rpc(
    'auth_record_logout',
  );
  if (error) {
    const mapped = mapDbError(error);
    if (mapped && NO_SHOP_SESSION.has(mapped.code)) {
      logger.info({ userId: auth.userId, code: mapped.code }, 'logout: no shop session, no audit');
    } else {
      logger.error({ err: error, userId: auth.userId }, 'logout: audit failed');
    }
  }
  const revoked = await revokeSession(auth.accessToken, 'local');
  if (!revoked) throw ServerError('Logout failed.');
}

// ============================================================================
// Forgot password (always 202, never says whether the account exists)
// ============================================================================

export async function forgotPassword(body: AuthForgotPasswordBody): Promise<void> {
  try {
    const identifier = body.identifier.trim().toLowerCase();
    const email = identifier.includes('@')
      ? identifier
      : body.tenantSlug
        ? await findLoginEmailByUsername(body.tenantSlug, identifier)
        : null;
    if (!email) return;

    const redirectTo = `${getEnv().FRONTEND_URL.replace(/\/+$/, '')}/reset-password`;
    const { error } = await createAuthClient().auth.resetPasswordForEmail(email, { redirectTo });
    if (error) logger.warn({ err: error }, 'forgotPassword: resetPasswordForEmail failed');
  } catch (err) {
    // The answer is the same whatever happens.
    logger.error({ err }, 'forgotPassword: failed');
  }
}

// ============================================================================
// Reset password (from the emailed recovery link)
// ============================================================================

/**
 * `token` is the access token of the recovery session (what the reset page gets from the
 * Supabase link) or the link's token_hash. Either way Supabase Auth validates it. A normal
 * password-login token is refused: it must come from the emailed link (amr method otp/recovery),
 * otherwise a stolen access token could change the password without the current one.
 */
export async function resetPassword(body: AuthResetPasswordBody): Promise<void> {
  let accessToken = body.token;
  if (!looksLikeJwt(body.token)) {
    const { data, error } = await createAuthClient().auth.verifyOtp({
      token_hash: body.token,
      type: 'recovery',
    });
    if (error && !isAuthClientError(error)) throw ServerError('Reset failed.');
    if (error || !data.session) throw tokenInvalid();
    accessToken = data.session.access_token;
  }

  const { data, error } = await createAuthClient().auth.getUser(accessToken);
  if (error && !isAuthClientError(error)) throw ServerError('Reset failed.');
  if (error || !data.user) throw tokenInvalid();
  const claims = decodeJwtPayload(accessToken);
  const fromRecoveryLink = (claims?.amr ?? []).some(
    (m) => m.method === 'otp' || m.method === 'recovery',
  );
  if (!fromRecoveryLink || claims?.sub !== data.user.id) throw tokenInvalid();

  await setPassword(accessToken, body.newPassword);

  // The recovery session and every other session of this user end here.
  const revoked = await revokeSession(accessToken, 'global');
  if (!revoked)
    logger.error({ userId: data.user.id }, 'P1: password reset but sessions not revoked');
}

async function setPassword(accessToken: string, newPassword: string): Promise<void> {
  let result;
  try {
    result = await updatePasswordWithToken(accessToken, newPassword);
  } catch (err) {
    logger.error({ err }, 'auth: password update call failed');
    throw ServerError('Password update failed.');
  }
  if (result.ok) return;
  if (result.status === 401 || result.status === 403) throw tokenInvalid();
  if (result.status === 400 || result.status === 422) {
    // same_password, weak_password, ...
    throw BadRequest('The new password was rejected.', 'VALIDATION_FAILED', {
      reason: result.code ?? 'rejected',
    });
  }
  logger.error({ status: result.status, code: result.code }, 'auth: password update failed');
  throw ServerError('Password update failed.');
}

// ============================================================================
// Change password (logged in)
// ============================================================================

export async function changePassword(
  auth: RequestAuth,
  body: AuthChangePasswordBody,
  meta: RequestMeta,
): Promise<void> {
  if (body.currentPassword === body.newPassword) {
    throw BadRequest('The new password must differ from the current one.', 'VALIDATION_FAILED');
  }
  const email = auth.email?.toLowerCase();
  if (!email) throw invalidCredentials();

  // The shop session must be clear before anything changes (the flag and audit need it).
  const { db } = await shopSessionClient(auth, meta);

  // Guessing the current password counts against the same lockout as login (D17).
  const attempt: LoginAttemptBase = {
    identifier: email,
    tenantSlug: null,
    ip: meta.ip,
    userAgent: meta.userAgent,
  };
  await lockoutCheck(email, null, attempt);
  const check = await signIn(email, body.currentPassword);
  if (!check) {
    await recordLoginAttempt({ ...attempt, success: false });
    throw invalidCredentials();
  }
  // The check created a session of its own; end it.
  await revokeSession(check.access_token, 'local');
  await recordLoginAttempt({ ...attempt, success: true });

  await setPassword(auth.accessToken, body.newPassword);

  const { error } = await db.rpc('auth_password_changed');
  if (error) {
    logger.error({ err: error, userId: auth.userId }, 'P1: password changed but flag/audit failed');
    throw dbError(error, 'auth_password_changed');
  }
  // Other devices must log in again with the new password; this session stays.
  await revokeSession(auth.accessToken, 'others');
}

// ============================================================================
// Shop session for authenticated auth routes (/me, change-password)
// ============================================================================

/**
 * The client for the caller's active shop:
 *   - x-org-id given: must be one of my_shops(), else SHOP_NOT_ALLOWED;
 *   - no header and exactly one usable shop: that shop;
 *   - no header and several: SHOP_SELECTION_REQUIRED; none: NOT_AN_EMPLOYEE.
 * The database applies the same rule again (app.current_org_id / app.require_session_employee).
 */
export async function shopSessionClient(
  auth: RequestAuth,
  meta: RequestMeta,
): Promise<{ db: DbClient; orgId: string }> {
  const shops = await myShops(supabaseForRequest(auth.accessToken, undefined, meta));
  let orgId: string;
  if (auth.orgId) {
    if (!shops.some((s) => s.orgId === auth.orgId)) {
      throw new AppError('Shop not allowed.', 'SHOP_NOT_ALLOWED');
    }
    orgId = auth.orgId;
  } else if (shops.length === 1 && shops[0]) {
    orgId = shops[0].orgId;
  } else if (shops.length > 1) {
    throw new AppError('Select a shop first.', 'SHOP_SELECTION_REQUIRED');
  } else {
    throw new AppError('Not an employee of an active shop.', 'NOT_AN_EMPLOYEE');
  }
  return { db: supabaseForRequest(auth.accessToken, orgId, meta), orgId };
}

// ============================================================================
// Me
// ============================================================================

export async function getMe(auth: RequestAuth, meta: RequestMeta): Promise<AuthMeResponse> {
  const { db, orgId } = await shopSessionClient(auth, meta);

  const { data: emp, error: empError } = await db
    .from('employees')
    .select('id, full_name, email, username, role, default_branch_id, must_change_password')
    .eq('auth_user_id', auth.userId)
    .eq('organization_id', orgId)
    .maybeSingle();
  if (empError) throw dbError(empError, 'me: employee');
  if (!emp) throw new AppError('Not an employee of an active shop.', 'NOT_AN_EMPLOYEE');

  const { data: org, error: orgError } = await db
    .from('organizations')
    .select('id, tenant_slug, name, timezone, default_language, status, plan_key, subscription_end')
    .eq('id', orgId)
    .maybeSingle();
  if (orgError) throw dbError(orgError, 'me: organization');
  if (!org) throw new AppError('Not an employee of an active shop.', 'NOT_AN_EMPLOYEE');

  let branches: AuthMeResponse['branches'];
  if (emp.role === 'OWNER') {
    const { data, error } = await db
      .from('branches')
      .select('id, code, name, is_main')
      .eq('is_active', true)
      .order('code');
    if (error) throw dbError(error, 'me: branches');
    branches = (data ?? []).map((b) => ({
      id: b.id,
      code: b.code,
      name: b.name,
      isMain: b.is_main,
    }));
  } else {
    const { data, error } = await db
      .from('employee_branches')
      .select('branches!inner(id, code, name, is_main, is_active)')
      .eq('employee_id', emp.id);
    if (error) throw dbError(error, 'me: branches');
    const rows = (data ?? []) as unknown as {
      branches: { id: string; code: string; name: string; is_main: boolean; is_active: boolean };
    }[];
    branches = rows
      .map((r) => r.branches)
      .filter((b) => b.is_active)
      .sort((a, b) => a.code.localeCompare(b.code))
      .map((b) => ({ id: b.id, code: b.code, name: b.name, isMain: b.is_main }));
  }

  return {
    employee: {
      id: emp.id,
      fullName: emp.full_name,
      email: emp.email,
      username: emp.username,
      role: emp.role,
      defaultBranchId: emp.default_branch_id,
      mustChangePassword: emp.must_change_password,
    },
    org: {
      id: org.id,
      tenantSlug: org.tenant_slug,
      name: org.name,
      timezone: org.timezone,
      defaultLanguage: org.default_language === 'en' ? 'en' : 'ar',
      status: org.status,
      planKey: org.plan_key,
      subscriptionEnd: org.subscription_end,
    },
    branches,
  };
}
