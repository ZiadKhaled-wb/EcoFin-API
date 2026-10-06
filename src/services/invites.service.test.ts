import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AuthApiError } from '@supabase/supabase-js';
const mock = vi.hoisted(() => ({
  rpc: vi.fn(),
  createUser: vi.fn(),
  deleteUser: vi.fn(),
  signIn: vi.fn(),
  signOut: vi.fn(),
}));
vi.mock('../utils/supabase', () => ({
  supabaseForInvite: () => ({
    rpc: mock.rpc,
    auth: { admin: { createUser: mock.createUser, deleteUser: mock.deleteUser } },
  }),
  createAuthClient: () => ({ auth: { signInWithPassword: mock.signIn, signOut: mock.signOut } }),
}));
import { acceptInvite, lookupInvite } from './invites.service';
const valid = {
  status: 'valid',
  shop_name: 'Shop',
  tenant_slug: 'shop-one',
  full_name: 'Owner',
  email: 'owner@example.com',
  account_exists: false,
};
beforeEach(() => {
  vi.clearAllMocks();
  mock.rpc.mockResolvedValue({ data: valid, error: null });
  mock.createUser.mockResolvedValue({ data: { user: { id: 'user-new' } }, error: null });
  mock.deleteUser.mockResolvedValue({ error: null });
  mock.signOut.mockResolvedValue({ error: null });
});
describe('pre-session invites', () => {
  it.each([
    ['expired', 410, 'INVITE_EXPIRED'],
    ['used', 410, 'INVITE_USED'],
    ['not_found', 404, 'INVITE_NOT_FOUND'],
  ])('maps %s lookup safely', async (status, statusCode, code) => {
    mock.rpc.mockResolvedValue({ data: { status }, error: null });
    await expect(lookupInvite('raw-token')).rejects.toMatchObject({ code, statusCode });
  });
  it('creates a new account, then accepts using only the hash', async () => {
    mock.rpc.mockResolvedValueOnce({ data: valid, error: null }).mockResolvedValueOnce({
      data: { tenant_slug: 'shop-one', email: valid.email },
      error: null,
    });
    await expect(acceptInvite({ token: 'raw-token', password: 'password-123' })).resolves.toEqual({
      tenant_slug: 'shop-one',
      email: valid.email,
    });
    expect(mock.createUser).toHaveBeenCalledWith({
      email: valid.email,
      password: 'password-123',
      email_confirm: true,
    });
    expect(mock.rpc.mock.calls[1]).toEqual([
      'accept_invite',
      { p_token_hash: expect.stringMatching(/^[a-f0-9]{64}$/), p_auth_user_id: 'user-new' },
    ]);
    expect(mock.createUser.mock.invocationCallOrder[0]).toBeLessThan(
      mock.rpc.mock.invocationCallOrder[1]!,
    );
  });
  it('removes a newly created account if acceptance fails', async () => {
    mock.rpc
      .mockResolvedValueOnce({ data: valid, error: null })
      .mockResolvedValueOnce({ data: null, error: { message: 'INVITE_USED' } });
    await expect(
      acceptInvite({ token: 'raw-token', password: 'password-123' }),
    ).rejects.toMatchObject({ code: 'INVITE_USED', statusCode: 410 });
    expect(mock.deleteUser).toHaveBeenCalledWith('user-new');
  });
  it('checks new-account password rules before account creation', async () => {
    await expect(acceptInvite({ token: 'raw-token', password: 'short' })).rejects.toMatchObject({
      code: 'VALIDATION_FAILED',
    });
    expect(mock.createUser).not.toHaveBeenCalled();
  });
  it('keeps the linked account if a committed response fails validation', async () => {
    mock.rpc
      .mockResolvedValueOnce({ data: valid, error: null })
      .mockResolvedValueOnce({ data: {}, error: null });
    await expect(acceptInvite({ token: 'raw-token', password: 'password-123' })).rejects.toThrow();
    expect(mock.deleteUser).not.toHaveBeenCalled();
  });
  it('does not accept or modify an existing account with a wrong password', async () => {
    mock.rpc.mockResolvedValue({ data: { ...valid, account_exists: true }, error: null });
    mock.signIn.mockResolvedValue({
      data: { user: null, session: null },
      error: new AuthApiError('Invalid credentials', 400, 'invalid_credentials'),
    });
    await expect(acceptInvite({ token: 'raw-token', password: 'old' })).rejects.toMatchObject({
      code: 'INVALID_CREDENTIALS',
      statusCode: 401,
    });
    expect(mock.rpc).toHaveBeenCalledTimes(1);
    expect(mock.createUser).not.toHaveBeenCalled();
    expect(mock.deleteUser).not.toHaveBeenCalled();
  });
  it('verifies an existing account, signs out the check session, and never sets its password', async () => {
    mock.rpc
      .mockResolvedValueOnce({ data: { ...valid, account_exists: true }, error: null })
      .mockResolvedValueOnce({
        data: { tenant_slug: 'shop-one', email: valid.email },
        error: null,
      });
    mock.signIn.mockResolvedValue({
      data: { user: { id: 'existing' }, session: { access_token: 'check' } },
      error: null,
    });
    await acceptInvite({ token: 'raw-token', password: 'old' });
    expect(mock.signOut).toHaveBeenCalledWith({ scope: 'local' });
    expect(mock.rpc).toHaveBeenLastCalledWith('accept_invite', {
      p_token_hash: expect.any(String),
      p_auth_user_id: 'existing',
    });
    expect(mock.createUser).not.toHaveBeenCalled();
    expect(mock.deleteUser).not.toHaveBeenCalled();
  });
});
