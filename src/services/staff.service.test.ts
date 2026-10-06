import { beforeEach, describe, it, expect, vi } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { createEmployee, resetEmployeePassword } from './staff.service';
import { completePasswordReset } from './passwordResets.service';
import { mapDbError } from '../utils/errors';
const mocks = vi.hoisted(() => ({ mail: vi.fn(), resetMail: vi.fn(), service: vi.fn() }));
vi.mock('../lib/mailer', () => ({
  sendInviteEmail: mocks.mail,
  sendPasswordResetEmail: mocks.resetMail,
}));
vi.mock('../utils/supabase', () => ({ supabaseForInvite: mocks.service }));
const id = '11111111-1111-4111-8111-111111111111';
const org = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
let db: ReturnType<typeof createSupabaseMock>;
let ctx: RequestContext;
beforeEach(() => {
  vi.clearAllMocks();
  db = createSupabaseMock();
  mocks.service.mockReturnValue(db);
  ctx = {
    db: db as unknown as DbClient,
    employeeId: id,
    orgId: org,
    userId: id,
    role: 'OWNER',
    branchIds: [],
    defaultBranchId: null,
    mustChangePassword: false,
  };
  mocks.mail.mockResolvedValue(true);
  process.env['FRONTEND_URL'] = 'http://localhost:5173';
});
describe('O02 staff delivery and reset ordering', () => {
  it('email delivers mail without returning a link; SQL receives only the hash', async () => {
    db.queue(
      {
        data: { employee_id: id, invite_email: 'staff@example.com', delivery: 'email' },
        error: null,
      },
      { data: { name: 'Shop' }, error: null },
    );
    const result = await createEmployee(ctx, {
      full_name: 'Staff',
      email: 'staff@example.com',
      role: 'CASHIER',
      branch_ids: [id],
      overrides: [],
    });
    expect(result).toEqual({ employee_id: id, delivery: 'email', email_sent: true });
    expect(mocks.mail).toHaveBeenCalledOnce();
    const args = db.rpc.mock.calls[0]?.[1] as { p_token_hash: string };
    expect(args.p_token_hash).toMatch(/^[a-f0-9]{64}$/);
    expect(JSON.stringify(args)).not.toContain('#token=');
  });
  it('username-only response has the link and sends no mail', async () => {
    db.queue({
      data: { employee_id: id, invite_email: 'staff@ecofin.invalid', delivery: 'link' },
      error: null,
    });
    const result = await createEmployee(ctx, {
      full_name: 'Staff',
      username: 'staff',
      role: 'CASHIER',
      branch_ids: [id],
      overrides: [],
    });
    expect(result.invite_link).toMatch(/\/invite\/accept#token=[\w-]{43}$/);
    expect(mocks.mail).not.toHaveBeenCalled();
  });
  it('reset consumes before auth admin update; failed update is RESET_FAILED', async () => {
    db.queue(
      {
        data: {
          status: 'valid',
          full_name: 'Staff',
          login: 'staff',
          shop_name: 'Shop',
          tenant_slug: 'shop-one',
        },
        error: null,
      },
      { data: id, error: null },
      { data: null, error: { message: 'failure' } },
    );
    await expect(
      completePasswordReset({ token: 'secret', password: 'NewPassword-123!' }),
    ).rejects.toMatchObject({ code: 'RESET_FAILED', statusCode: 500 });
    expect(db.rpc.mock.calls.map((c) => c[0])).toEqual([
      'password_reset_lookup',
      'consume_password_reset',
    ]);
    expect(db.rpc.mock.invocationCallOrder[1]).toBeLessThan(
      db.auth.admin.updateUserById.mock.invocationCallOrder[0]!,
    );
  });
  it('reset link has a 24 hour expiry and no email delivery', async () => {
    db.queue({ data: { delivery: 'link', email: 'staff@ecofin.invalid' }, error: null });
    const result = await resetEmployeePassword(ctx, id);
    expect(result.reset_link).toMatch(/\/password\/set#token=/);
    expect(Date.parse(result.expires_at) - Date.now()).toBeGreaterThan(86390000);
    expect(mocks.resetMail).not.toHaveBeenCalled();
  });
  it.each([
    ['EMAIL_TAKEN', 409],
    ['USERNAME_TAKEN', 409],
    ['INVITE_ALREADY_ACCEPTED', 409],
    ['PERMISSION_ESCALATION', 403],
    ['TARGET_NOT_ALLOWED', 403],
    ['ROLE_NOT_ALLOWED', 403],
    ['EMPLOYEE_NOT_FOUND', 404],
    ['LOGIN_REQUIRED', 400],
    ['USERNAME_INVALID', 400],
    ['BRANCH_REQUIRED', 400],
    ['LOGIN_LOCKED', 400],
    ['EMPLOYEE_NOT_LINKED', 400],
    ['EMPLOYEE_INACTIVE', 400],
    ['REASON_REQUIRED', 400],
    ['RESET_USED', 410],
    ['RESET_EXPIRED', 410],
  ])('%s maps safely', (code, status) => {
    expect(mapDbError({ message: code + ': private details' })).toMatchObject({
      code,
      statusCode: status,
    });
    expect(mapDbError({ message: code + ': private details' })?.message).not.toContain('private');
  });
});

it('mail failure returns email_sent false and logs neither token nor link', async () => {
  const { logger } = await import('../utils/logger');
  const logs = [vi.spyOn(logger, 'info'), vi.spyOn(logger, 'warn'), vi.spyOn(logger, 'error')];
  let secret = '';
  mocks.mail.mockImplementation(async (message: { link: string }) => {
    secret = message.link;
    throw new Error(message.link);
  });
  db.queue(
    {
      data: { employee_id: id, invite_email: 'staff@example.com', delivery: 'email' },
      error: null,
    },
    { data: { name: 'Shop' }, error: null },
  );
  const result = await createEmployee(ctx, {
    full_name: 'Staff',
    email: 'staff@example.com',
    role: 'CASHIER',
    branch_ids: [id],
    overrides: [],
  });
  expect(result.email_sent).toBe(false);
  expect(result.invite_link).toBeUndefined();
  for (const log of logs) {
    expect(JSON.stringify(log.mock.calls)).not.toContain(secret);
    expect(JSON.stringify(log.mock.calls)).not.toContain(new URL(secret).hash.slice(7));
    log.mockRestore();
  }
});
it('email password reset sends bilingual mail without returning a link', async () => {
  mocks.resetMail.mockResolvedValue(true);
  db.queue(
    { data: { delivery: 'email', email: 'staff@example.com' }, error: null },
    { data: { id, full_name: 'Staff' }, error: null },
    { data: { name: 'Shop' }, error: null },
  );
  const result = await resetEmployeePassword(ctx, id);
  expect(result).toMatchObject({ delivery: 'email', email_sent: true });
  expect(result.reset_link).toBeUndefined();
  expect(mocks.resetMail).toHaveBeenCalledWith(
    expect.objectContaining({
      email: 'staff@example.com',
      shopName: 'Shop',
      link: expect.stringContaining('/password/set#token='),
    }),
  );
});
it('successful reset returns login context and never calls admin before consume', async () => {
  db.queue(
    {
      data: {
        status: 'valid',
        full_name: 'Staff',
        login: 'staff',
        shop_name: 'Shop',
        tenant_slug: 'shop-one',
      },
      error: null,
    },
    { data: id, error: null },
    { data: { user: { id } }, error: null },
  );
  expect(
    await completePasswordReset({ token: 'reset-token', password: 'NewPassword-123!' }),
  ).toEqual({ login: 'staff', tenant_slug: 'shop-one' });
  expect(db.rpc.mock.invocationCallOrder[1]).toBeLessThan(
    db.auth.admin.updateUserById.mock.invocationCallOrder[0]!,
  );
});
it('used reset never updates the auth user', async () => {
  db.queue({ data: { status: 'used' }, error: null });
  await expect(
    completePasswordReset({ token: 'reset-token', password: 'NewPassword-123!' }),
  ).rejects.toMatchObject({ code: 'RESET_USED' });
  expect(db.auth.admin.updateUserById).not.toHaveBeenCalled();
});
