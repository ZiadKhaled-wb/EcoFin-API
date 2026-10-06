import {
  PasswordResetLookupResult,
  PasswordResetLookupResponse,
  PasswordResetCompleteResponse,
  PasswordResetCompleteBody,
} from '@ziadkhaled-wb/contracts';
import { supabaseForInvite, type DbClient, type RequestMeta } from '../utils/supabase';
import { hashInviteToken } from '../utils/inviteToken';
import { AppError, mapDbError, ServerError } from '../utils/errors';
async function lookup(token: string, db: DbClient) {
  const { data, error } = await db.rpc('password_reset_lookup', {
    p_token_hash: hashInviteToken(token),
  });
  if (error) throw mapDbError(error) ?? ServerError('Request failed.');
  const result = PasswordResetLookupResult.parse(data);
  if (result.status === 'not_found') throw new AppError('Reset not found.', 'RESET_NOT_FOUND');
  if (result.status === 'expired') throw new AppError('Reset expired.', 'RESET_EXPIRED');
  if (result.status === 'used') throw new AppError('Reset used.', 'RESET_USED');
  if (result.status !== 'valid') throw ServerError('Request failed.');
  return result;
}
// Fresh service-role client only in the pre-session lookup/complete flow; shop requests use caller JWTs.
export async function lookupPasswordReset(token: string, meta?: RequestMeta) {
  return PasswordResetLookupResponse.parse(await lookup(token, supabaseForInvite(meta)));
}
export async function completePasswordReset(body: PasswordResetCompleteBody, meta?: RequestMeta) {
  const parsed = PasswordResetCompleteBody.parse(body);
  const db = supabaseForInvite(meta);
  const info = await lookup(parsed.token, db);
  const { data, error } = await db.rpc('consume_password_reset', {
    p_token_hash: hashInviteToken(parsed.token),
  });
  if (error) throw mapDbError(error) ?? ServerError('Request failed.');
  if (!data) throw new AppError('Reset failed.', 'RESET_FAILED');
  try {
    const result = await db.auth.admin.updateUserById(data, { password: parsed.password });
    if (result.error) throw new Error('Reset failed');
  } catch {
    throw new AppError('Reset failed.', 'RESET_FAILED');
  }
  return PasswordResetCompleteResponse.parse({ login: info.login, tenant_slug: info.tenant_slug });
}
