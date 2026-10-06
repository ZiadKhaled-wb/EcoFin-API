import { createHash } from 'node:crypto';
import { describe, expect, it, vi } from 'vitest';
vi.mock('./env', () => ({
  getEnv: () => ({ INVITE_TTL_HOURS: 72, FRONTEND_URL: 'https://shop.example/' }),
}));
import { createInviteToken, hashInviteToken } from './inviteToken';

describe('invite tokens', () => {
  it('uses 32 random bytes, SHA-256, and the configured TTL', () => {
    const now = new Date('2026-10-06T00:00:00Z');
    const a = createInviteToken(now);
    const b = createInviteToken(now);
    expect(a.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(a.token).not.toBe(b.token);
    expect(a.hash).toBe(createHash('sha256').update(a.token).digest('hex'));
    expect(hashInviteToken(a.token)).toBe(a.hash);
    expect(a.expiresAt).toBe('2026-10-09T00:00:00.000Z');
    expect(a.link).toBe(`https://shop.example/invite/accept#token=${a.token}`);
  });
});
