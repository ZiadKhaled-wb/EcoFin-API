// server/src/utils/authErrors.ts
//
// Supabase Auth errors come in several classes: AuthApiError for most API answers, but also
// AuthSessionMissingError (GoTrue `session_not_found`, e.g. a logged-out session),
// AuthInvalidJwtError and others. What matters to us is whether Supabase Auth *refused* the
// caller's token or input (a 4xx other than 429), or could not answer: network error, 5xx, or
// its own rate limit (429). Only a refusal may become TOKEN_INVALID / INVALID_CREDENTIALS;
// anything else is our 500, so the client never logs a user out because Supabase was busy.
import { isAuthError } from '@supabase/supabase-js';

export function authErrorStatus(err: unknown): number | undefined {
  if (!isAuthError(err)) return undefined;
  const status = (err as { status?: unknown }).status;
  return typeof status === 'number' ? status : undefined;
}

/** True when Supabase Auth refused the request (4xx, not 429): the token or input is bad. */
export function isAuthClientError(err: unknown): boolean {
  const status = authErrorStatus(err);
  return status !== undefined && status >= 400 && status < 500 && status !== 429;
}
