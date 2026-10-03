// server/src/utils/supabase.ts
//
// ============================================================================
// USAGE RULES — READ BEFORE ADDING AN IMPORT
// ============================================================================
//
// Three Supabase clients. Using the wrong one in the wrong place is a
// security bug, not a style issue.
//
//   * supabaseAnon
//       - anon key, no session persistence.
//       - Pre-auth AUTH calls only: signInWithPassword, resetPasswordForEmail.
//       - Respects Supabase's own rate limiting on the Auth API.
//
//   * supabaseUser(jwt)
//       - anon key + caller's JWT in the Authorization header.
//       - EVERY tenant-scoped query AFTER the caller is authenticated.
//       - RLS is enforced. That is the point. If a query returns nothing
//         when it should return rows, the fix is a policy, not a bigger key.
//
//   * supabaseAdmin
//       - service-role key. Bypasses RLS.
//       - ONLY used for:
//           (a) pre-auth bootstrap (login identifier resolution,
//               check-license, activate-workspace, forgot-password);
//           (b) Super Admin platform operations (issuing licenses,
//               provisioning tenants);
//           (c) background jobs / admin scripts;
//           (d) auth.admin.* calls (createUser, updateUserById, ...).
//       - NEVER for tenant CRUD after authentication. If you are tempted to
//         write `supabaseAdmin.from('contracts')` inside a tenant request
//         handler, you have a bug — use `supabaseUser(jwt)` instead.
//
// ============================================================================

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { getEnv } from './env';

const baseAuthOptions = {
  persistSession: false,
  autoRefreshToken: false,
  detectSessionInUrl: false,
} as const;

/**
 * The env is read on first use, not at import, so importing this module never throws and tests
 * can import it freely. Startup validates the env separately (getEnv() in server.ts / worker.ts).
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

export const supabaseAnon: SupabaseClient = lazyClient(() => {
  const env = getEnv();
  return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, { auth: baseAuthOptions });
});

export function supabaseUser(jwt: string): SupabaseClient {
  if (!jwt) {
    // Programming error — never silently fall back to anon.
    throw new Error('supabaseUser() requires a non-empty JWT.');
  }
  const env = getEnv();
  return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    auth: baseAuthOptions,
    global: {
      headers: { Authorization: `Bearer ${jwt}` },
    },
  });
}

export const supabaseAdmin: SupabaseClient = lazyClient(() => {
  const env = getEnv();
  return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: baseAuthOptions });
});
