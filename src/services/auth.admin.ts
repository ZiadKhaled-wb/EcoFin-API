// server/src/services/auth.admin.ts
//
// The ONLY place the service role is used for auth (D14). Pre-session steps only:
//   - resolve tenantSlug + username to the login email,
//   - read the login's memberships to refuse inactive employees, inactive shops and expired
//     subscriptions before tokens are handed out,
//   - count and insert login_attempts (the baseline grants that table to the service role only).
// Everything after login uses supabaseForRequest(<user JWT>).
//
// Errors from these queries are logged here and thrown as a generic INTERNAL error, so no raw
// database message reaches the client.

import { supabaseAdmin } from '../utils/supabase';
import { ServerError } from '../utils/errors';
import { logger } from '../utils/logger';
import type { OrgStatus } from '@ecotech/contracts';
import type { Database } from '../types/database.types';

type EmployeeRole = Database['public']['Enums']['employee_role'];

export interface MembershipRow {
  employeeId: string;
  orgId: string;
  orgName: string;
  tenantSlug: string;
  role: EmployeeRole;
  isActive: boolean;
  archived: boolean;
  mustChangePassword: boolean;
  orgStatus: OrgStatus;
  subscriptionEnd: string | null;
  timezone: string;
}

interface MembershipQueryRow {
  id: string;
  role: EmployeeRole;
  is_active: boolean;
  archived_at: string | null;
  must_change_password: boolean;
  organizations: {
    id: string;
    name: string;
    tenant_slug: string;
    status: OrgStatus;
    subscription_end: string | null;
    timezone: string;
  } | null;
}

/** Identifiers are stored and compared capped, so a huge body can't bloat login_attempts. */
const MAX_IDENTIFIER = 320;
const capped = (identifier: string) => identifier.slice(0, MAX_IDENTIFIER);

function fail(err: unknown, what: string): never {
  logger.error({ err }, `auth.admin: ${what} failed`);
  throw ServerError('Login failed.');
}

/** `tenantSlug + username` -> the login's email (auth.users), or null when nothing matches. */
export async function findLoginEmailByUsername(
  tenantSlug: string,
  username: string,
): Promise<string | null> {
  const { data, error } = await supabaseAdmin
    .from('employees')
    .select('auth_user_id, organizations!inner(tenant_slug)')
    .eq('organizations.tenant_slug', tenantSlug)
    .eq('username', username)
    .maybeSingle();
  if (error) fail(error, 'username lookup');
  const authUserId = (data as { auth_user_id: string | null } | null)?.auth_user_id;
  if (!authUserId) return null;

  const { data: user, error: userError } = await supabaseAdmin.auth.admin.getUserById(authUserId);
  if (userError) {
    // A dangling auth_user_id is treated like an unknown user (same INVALID_CREDENTIALS).
    logger.warn({ err: userError }, 'auth.admin: auth user lookup failed');
    return null;
  }
  return user.user?.email?.toLowerCase() ?? null;
}

/** Every employee row of one login, with its shop. Inactive rows included (to name the refusal). */
export async function loadMemberships(authUserId: string): Promise<MembershipRow[]> {
  const { data, error } = await supabaseAdmin
    .from('employees')
    .select(
      'id, role, is_active, archived_at, must_change_password, organizations!inner(id, name, tenant_slug, status, subscription_end, timezone)',
    )
    .eq('auth_user_id', authUserId);
  if (error) fail(error, 'membership lookup');
  const rows = (data ?? []) as unknown as MembershipQueryRow[];
  return rows.flatMap((row) => {
    const org = row.organizations;
    if (!org) return [];
    return [
      {
        employeeId: row.id,
        orgId: org.id,
        orgName: org.name,
        tenantSlug: org.tenant_slug,
        role: row.role,
        isActive: row.is_active,
        archived: row.archived_at !== null,
        mustChangePassword: row.must_change_password,
        orgStatus: org.status,
        subscriptionEnd: org.subscription_end,
        timezone: org.timezone,
      },
    ];
  });
}

/**
 * Failed attempts inside the window. Emails are counted across shops (the slug does not change
 * who signs in); usernames are counted per shop (D17: per identifier, per shop).
 */
export async function countRecentFailures(
  identifier: string,
  tenantSlug: string | null,
  windowMinutes: number,
): Promise<number> {
  const since = new Date(Date.now() - windowMinutes * 60_000).toISOString();
  let query = supabaseAdmin
    .from('login_attempts')
    .select('id', { count: 'exact', head: true })
    .eq('identifier', capped(identifier))
    .eq('success', false)
    .gte('created_at', since);
  if (tenantSlug !== null) query = query.eq('tenant_slug', tenantSlug);
  const { count, error } = await query;
  if (error) fail(error, 'login_attempts count');
  return count ?? 0;
}

export interface LoginAttempt {
  identifier: string;
  tenantSlug: string | null;
  success: boolean;
  ip?: string | undefined;
  userAgent?: string | undefined;
}

/** One row per attempt. The ip column is inet: anything that isn't an IP is stored as NULL. */
export async function recordLoginAttempt(attempt: LoginAttempt): Promise<void> {
  const { error } = await supabaseAdmin.from('login_attempts').insert({
    identifier: capped(attempt.identifier),
    tenant_slug: attempt.tenantSlug,
    success: attempt.success,
    ip: attempt.ip && isIp(attempt.ip) ? attempt.ip : null,
    user_agent: attempt.userAgent ? attempt.userAgent.slice(0, 512) : null,
  });
  if (error) fail(error, 'login_attempts insert');
}

function isIp(value: string): boolean {
  return /^[0-9a-fA-F:.]+$/.test(value) && value.length <= 45;
}
