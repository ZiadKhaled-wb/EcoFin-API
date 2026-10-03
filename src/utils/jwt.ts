// server/src/utils/jwt.ts
//
// Reads the payload of a JWT WITHOUT checking its signature. Only call it on a token that
// Supabase Auth has already accepted (getUser / verifyOtp), or to pick an error code.
// Never use the result to decide who the caller is.

export interface JwtPayload {
  sub?: string;
  exp?: number;
  session_id?: string;
  amr?: { method?: string; timestamp?: number }[];
}

export function decodeJwtPayload(token: string): JwtPayload | undefined {
  const parts = token.split('.');
  if (parts.length !== 3 || !parts[1]) return undefined;
  try {
    const json: unknown = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    return typeof json === 'object' && json !== null ? json : undefined;
  } catch {
    return undefined;
  }
}

/** A JWT has three base64url parts; a recovery token_hash is plain hex. */
export function looksLikeJwt(token: string): boolean {
  return /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token);
}
