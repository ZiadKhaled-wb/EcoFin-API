// server/src/utils/supabase.ts
//
// ============================================================================
// USAGE RULES — READ BEFORE ADDING AN IMPORT
// ============================================================================
//
// No client in this module ever holds a user session that another request could reuse.
//
//   * supabaseForRequest(accessToken, orgId?, meta?)
//       - A NEW client for each request: anon key + the caller's JWT in the Authorization header
//         (+ `x-org-id` for the active shop). Every DB read or write after login goes through it,
//         so RLS and the SECURITY DEFINER functions see the real caller.
//
//   * createAuthClient()
//       - A NEW anon client for one Supabase Auth call (sign in, refresh, verify a recovery
//         token, send the reset email, sign out). Sign-in stores the session inside the client
//         object, so a shared client would carry one user's session into the next request.
//         Never keep the returned client beyond the call.
//
//   * supabaseAdmin (service role, bypasses RLS)
//       - Only in src/services/auth.admin.ts (D14: pre-session auth steps), the health
//         check (D20), the background job worker in src/jobs/ (D34: platform jobs through
//         the service-role-only jobs_* functions), src/services/storage.service.ts (D36: the
//         private file bucket, after the session, shop and permission checks) and
//         scripts/files-orphan-report.ts (D36: report only). Never for tenant data in a user request.
//
// ============================================================================

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '../types/database.types';
import { getEnv } from './env';
import { validDeviceId } from './validation';

export type DbClient = SupabaseClient<Database>;

const baseAuthOptions = {
  persistSession: false,
  autoRefreshToken: false,
  detectSessionInUrl: false,
  // Implicit flow: recovery links carry the session in the redirect, no code verifier to keep.
  flowType: 'implicit',
} as const;

/** Request details passed to PostgREST so app.write_audit can record them. */
export interface RequestMeta {
  /** The client IP as Express resolved it behind `trust proxy`, never the raw header chain. */
  ip?: string | undefined;
  userAgent?: string | undefined;
  requestId?: string | undefined;
  /** The client's `x-device-id` (F07), only when it is a UUID; the DB drops another shop's device. */
  deviceId?: string | undefined;
}

/**
 * The env is read on first use, not at import, so importing this module never throws and tests
 * can import it freely. Startup validates the env separately (getEnv() in server.ts).
 */
function lazyClient(create: () => SupabaseClient): SupabaseClient {
  let client: SupabaseClient | undefined;
  return new Proxy({} as SupabaseClient, {
    get(_target, prop) {
      client ??= create();
      const value: unknown = Reflect.get(client, prop, client);
      return typeof value === 'function' ? value.bind(client) : value;
    },
  });
}

/** A fresh anon client for one Supabase Auth call. See the rules at the top. */
export function createAuthClient(): SupabaseClient {
  const env = getEnv();
  return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, { auth: baseAuthOptions });
}

/**
 * A fresh client that runs as the caller. `orgId` (already checked to be a UUID) becomes the
 * `x-org-id` header that app.current_org_id() reads; the database still decides whether the
 * caller belongs to that shop.
 */
export function supabaseForRequest(
  accessToken: string,
  orgId?: string,
  meta?: RequestMeta,
): DbClient {
  if (!accessToken) {
    // Programming error — never silently fall back to anon.
    throw new Error('supabaseForRequest() requires a non-empty access token.');
  }
  const env = getEnv();
  const headers: Record<string, string> = { Authorization: `Bearer ${accessToken}` };
  if (orgId) headers['x-org-id'] = orgId;
  if (meta?.ip) headers['x-forwarded-for'] = meta.ip;
  if (meta?.userAgent) headers['user-agent'] = meta.userAgent;
  if (meta?.requestId) headers['x-request-id'] = meta.requestId;
  // app.write_audit (F07) reads these request headers for every audit row.
  const deviceId = validDeviceId(meta?.deviceId);
  if (deviceId) headers['x-device-id'] = deviceId;
  return createClient<Database>(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    auth: baseAuthOptions,
    global: { headers },
  });
}

/** Fresh service role only for P01/O02 pre-session invite/reset lookup and completion; preserve F07 metadata. */
export function supabaseForInvite(meta?: RequestMeta): DbClient {
  const env = getEnv();
  const headers: Record<string, string> = {};
  if (meta?.ip) headers['x-forwarded-for'] = meta.ip;
  if (meta?.userAgent) headers['user-agent'] = meta.userAgent;
  if (meta?.requestId) headers['x-request-id'] = meta.requestId;
  return createClient<Database>(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: baseAuthOptions,
    global: { headers },
  });
}

export interface PasswordUpdateResult {
  ok: boolean;
  status: number;
  /** GoTrue error code, e.g. `same_password`, `weak_password`. */
  code?: string | undefined;
}

/**
 * Sets a new password for the user who owns `accessToken` (PUT /auth/v1/user).
 * supabase-js `updateUser` needs a stored session (access + refresh token); the API only has the
 * access token, so this calls the same GoTrue endpoint directly. Nothing from the response body
 * except the error code is returned.
 */
export async function updatePasswordWithToken(
  accessToken: string,
  password: string,
): Promise<PasswordUpdateResult> {
  const env = getEnv();
  const res = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
    method: 'PUT',
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ password }),
  });
  if (res.ok) return { ok: true, status: res.status };
  let code: string | undefined;
  try {
    const body = (await res.json()) as { error_code?: unknown };
    if (typeof body.error_code === 'string') code = body.error_code;
  } catch {
    code = undefined;
  }
  return { ok: false, status: res.status, code };
}

/**
 * Service role. Only for src/services/auth.admin.ts (D14), the health check (D20), src/jobs (D34)
 * and src/eta (D67: the worker-side receipt functions).
 */
export const supabaseAdmin: SupabaseClient = lazyClient(() => {
  const env = getEnv();
  return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: baseAuthOptions });
});
