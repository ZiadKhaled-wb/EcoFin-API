import {
  InviteLookupResult,
  InviteLookupResponse,
  InviteAcceptResponse,
  Password,
  type InviteAcceptBody,
} from '@ziadkhaled-wb/contracts';
import {
  supabaseForInvite,
  createAuthClient,
  type DbClient,
  type RequestMeta,
} from '../utils/supabase';
import { hashInviteToken } from '../utils/inviteToken';
import { AppError, BadRequest, ServerError, Unauthorized, mapDbError } from '../utils/errors';
import { isAuthClientError } from '../utils/authErrors';
import { logger } from '../utils/logger';

async function lookup(token: string, db: DbClient) {
  const { data, error } = await db.rpc('invite_lookup', { p_token_hash: hashInviteToken(token) });
  if (error) throw mapDbError(error) ?? ServerError('Request failed.');
  const result = InviteLookupResult.parse(data);
  if (result.status === 'not_found') throw new AppError('Invite not found.', 'INVITE_NOT_FOUND');
  if (result.status === 'expired') throw new AppError('Invite expired.', 'INVITE_EXPIRED');
  if (result.status === 'used') throw new AppError('Invite used.', 'INVITE_USED');
  if (result.status !== 'valid') throw ServerError('Request failed.');
  return result;
}
export async function lookupInvite(token: string, meta?: RequestMeta) {
  return InviteLookupResponse.parse(await lookup(token, supabaseForInvite(meta)));
}
export async function acceptInvite(body: InviteAcceptBody, meta?: RequestMeta) {
  const db = supabaseForInvite(meta);
  const invite = await lookup(body.token, db);
  let userId: string;
  let created = false;
  if (!invite.account_exists) {
    const password = Password.safeParse(body.password);
    if (!password.success) throw BadRequest('Invalid password.', 'VALIDATION_FAILED');
    const { data, error } = await db.auth.admin.createUser({
      email: invite.email,
      password: password.data,
      email_confirm: true,
    });
    if (error || !data.user) throw ServerError('Account creation failed.');
    userId = data.user.id;
    created = true;
  } else {
    const client = createAuthClient();
    const { data, error } = await client.auth.signInWithPassword({
      email: invite.email,
      password: body.password,
    });
    if (error) {
      if (isAuthClientError(error))
        throw Unauthorized('Invalid credentials.', 'INVALID_CREDENTIALS');
      throw ServerError('Authentication failed.');
    }
    if (!data.user || !data.session)
      throw Unauthorized('Invalid credentials.', 'INVALID_CREDENTIALS');
    userId = data.user.id;
    const signedOut = await client.auth.signOut({ scope: 'local' });
    if (signedOut.error) throw ServerError('Authentication failed.');
  }
  const result = await (async () => {
    try {
      const { data, error } = await db.rpc('accept_invite', {
        p_token_hash: hashInviteToken(body.token),
        p_auth_user_id: userId,
      });
      if (error) throw mapDbError(error) ?? ServerError('Request failed.');
      return data;
    } catch (error) {
      if (created) {
        const cleanup = await db.auth.admin.deleteUser(userId);
        if (cleanup.error) logger.error({ userId }, 'invite account cleanup failed');
      }
      throw error;
    }
  })();
  return InviteAcceptResponse.parse(result);
}
