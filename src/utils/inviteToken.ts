import { createHash, randomBytes } from 'node:crypto';
import { getEnv } from './env';

export const hashInviteToken = (token: string): string =>
  createHash('sha256').update(token).digest('hex');

/** Raw token and link stay in memory until email delivery; only the hash is passed to SQL. */
export function createInviteToken(now: Date = new Date()) {
  const env = getEnv();
  const token = randomBytes(32).toString('base64url');
  return {
    token,
    hash: hashInviteToken(token),
    expiresAt: new Date(now.getTime() + env.INVITE_TTL_HOURS * 3600_000).toISOString(),
    link: `${env.FRONTEND_URL.replace(/\/+$/, '')}/invite/accept#token=${token}`,
  };
}
