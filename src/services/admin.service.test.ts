import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { DbClient } from '../utils/supabase';
const mock = vi.hoisted(() => ({
  rpc: vi.fn(),
  mail: vi.fn(),
  info: vi.fn(),
  warn: vi.fn(),
  error: vi.fn(),
}));
vi.mock('../lib/mailer', () => ({ sendInviteEmail: mock.mail }));
vi.mock('../utils/logger', () => ({
  logger: { info: mock.info, warn: mock.warn, error: mock.error },
}));
vi.mock('../utils/env', () => ({
  getEnv: () => ({ INVITE_TTL_HOURS: 72, FRONTEND_URL: 'https://shop.example' }),
}));
import { provisionShop, resendOwnerInvite } from './admin.service';
import { mapDbError } from '../utils/errors';
const db = { rpc: mock.rpc } as unknown as DbClient;
const ORG = 'a0100000-0000-4000-8000-000000000001';
const body = {
  name: 'Shop',
  tenant_slug: 'shop-one',
  plan_key: 'starter',
  owner: { full_name: 'Owner', email: 'owner@example.com' },
};
beforeEach(() => {
  vi.clearAllMocks();
  mock.rpc.mockResolvedValue({
    data: {
      organization_id: ORG,
      owner_employee_id: 'a0100000-0000-4000-8000-000000000002',
      branch_id: 'a0100000-0000-4000-8000-000000000003',
      invite_id: 'a0100000-0000-4000-8000-000000000004',
    },
    error: null,
  });
  mock.mail.mockResolvedValue(true);
});
describe('platform provisioning', () => {
  it('sends the email only after provisioning and never exposes or logs the token', async () => {
    const result = await provisionShop(db, body);
    const message = mock.mail.mock.calls[0]![0] as { link: string };
    const token = new URL(message.link).hash.slice('#token='.length);
    expect(mock.rpc.mock.invocationCallOrder[0]).toBeLessThan(
      mock.mail.mock.invocationCallOrder[0]!,
    );
    expect(mock.rpc.mock.calls[0]![1]).toMatchObject({
      p_token_hash: expect.stringMatching(/^[a-f0-9]{64}$/),
    });
    expect(JSON.stringify(result)).not.toContain(token);
    for (const log of [mock.info, mock.warn, mock.error])
      expect(JSON.stringify(log.mock.calls)).not.toContain(token);
    expect(result.invite_email_sent).toBe(true);
  });
  it('keeps provisioning successful when email delivery fails', async () => {
    mock.mail.mockRejectedValue(new Error('SMTP failed'));
    await expect(provisionShop(db, body)).resolves.toMatchObject({
      organization_id: ORG,
      invite_email_sent: false,
    });
    expect(mock.rpc).toHaveBeenCalledTimes(1);
  });
  it('does not send email when the transaction fails', async () => {
    mock.rpc.mockResolvedValue({ data: null, error: { message: 'SLUG_TAKEN' } });
    await expect(provisionShop(db, body)).rejects.toMatchObject({
      code: 'SLUG_TAKEN',
      statusCode: 409,
    });
    expect(mock.mail).not.toHaveBeenCalled();
  });
  it('resends through the caller RPC before sending and returns no link', async () => {
    mock.rpc.mockResolvedValue({
      data: {
        email: body.owner.email,
        owner_full_name: 'Owner',
        shop_name: 'Shop',
        expires_at: '2026-10-09T00:00:00.000Z',
      },
      error: null,
    });
    const result = await resendOwnerInvite(db, 'org');
    expect(mock.rpc).toHaveBeenCalledWith(
      'admin_resend_owner_invite',
      expect.objectContaining({ p_organization_id: 'org' }),
    );
    expect(result).not.toHaveProperty('link');
    expect(result).not.toHaveProperty('token');
  });
  it.each([
    ['SUPER_ADMIN_REQUIRED', 403],
    ['ORG_NOT_FOUND', 404],
    ['SLUG_INVALID', 400],
    ['INVITE_USED', 410],
    ['INVITE_EXPIRED', 410],
  ])('maps %s', (code, statusCode) => {
    expect(mapDbError({ message: `${code}: private detail` })).toMatchObject({ code, statusCode });
  });
});
