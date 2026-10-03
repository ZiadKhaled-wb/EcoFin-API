// server/src/utils/authErrors.ts
//
// Supabase Auth errors come in several classes: AuthApiError for most API answers, but also
// AuthSessionMissingError (GoTrue `session_not_found`, e.g. a logged-out session),
// AuthInvalidJwtError and others. What matters to us is whether Supabase Auth *refused* the
// request (4xx: bad token, wrong password, used refresh token) or could not answer
// (network error, 5xx). The first is a client error; the second is our 500.
import { isAuthError } from '@supabase/supabase-js';

/** True when Supabase Auth answered with a 4xx (the caller's token or input was refused). */
export function isAuthClientError(err: unknown): boolean {
  if (!isAuthError(err)) return false;
  const status = (err as { status?: unknown }).status;
  return typeof status === 'number' && status >= 400 && status < 500;
}

export function authErrorStatus(err: unknown): number | undefined {
  if (!isAuthError(err)) return undefined;
  const status = (err as { status?: unknown }).status;
  return typeof status === 'number' ? status : undefined;
}
