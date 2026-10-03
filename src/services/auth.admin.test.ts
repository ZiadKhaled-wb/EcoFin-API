// Service-role helpers (D14). The admin client is the shared chainable mock.
import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('../utils/supabase', async () => {
  const { createSupabaseMock } = await import('../test/supabase-mock');
  return { supabaseAdmin: createSupabaseMock() };
});

import { supabaseAdmin } from '../utils/supabase';
import type { SupabaseMock } from '../test/supabase-mock';
import {
  countRecentFailures,
  findLoginEmailByUsername,
  loadMemberships,
  recordLoginAttempt,
  clearMustChangePassword,
} from './auth.admin';

const mock = supabaseAdmin as unknown as SupabaseMock;

beforeEach(() => {
  mock.reset();
  vi.clearAllMocks();
});

describe('findLoginEmailByUsername', () => {
  it('returns the auth email of the employee with that username in that shop', async () => {
    mock.queue(
      { data: { auth_user_id: 'u1' }, error: null },
      { data: { user: { email: 'Owner.One@EcoTech.test' } }, error: null },
    );
    await expect(findLoginEmailByUsername('shop-a', 'owner.one')).resolves.toBe(
      'owner.one@ecotech.test',
    );
    expect(mock.eq).toHaveBeenCalledWith('organizations.tenant_slug', 'shop-a');
    expect(mock.eq).toHaveBeenCalledWith('username', 'owner.one');
    expect(mock.auth.admin.getUserById).toHaveBeenCalledWith('u1');
  });

  it('unknown username or slug -> null (no auth lookup)', async () => {
    mock.queue({ data: null, error: null });
    await expect(findLoginEmailByUsername('shop-a', 'nobody')).resolves.toBeNull();
    expect(mock.auth.admin.getUserById).not.toHaveBeenCalled();
  });

  it('a database error becomes a generic 500 (no raw message)', async () => {
    mock.queue({ data: null, error: { message: 'relation "x" does not exist' } });
    await expect(findLoginEmailByUsername('shop-a', 'x.y')).rejects.toMatchObject({
      statusCode: 500,
      code: 'INTERNAL',
      message: 'Login failed.',
    });
  });
});

describe('loadMemberships', () => {
  it('maps employee + shop rows for one login', async () => {
    mock.queue({
      data: [
        {
          id: 'e1',
          role: 'OWNER',
          is_active: true,
          archived_at: null,
          must_change_password: true,
          organizations: {
            id: 'o1',
            name: 'Shop',
            tenant_slug: 'shop-a',
            status: 'active',
            subscription_end: '2027-01-01',
            timezone: 'Africa/Cairo',
          },
        },
      ],
      error: null,
    });
    const rows = await loadMemberships('u1');
    expect(mock.eq).toHaveBeenCalledWith('auth_user_id', 'u1');
    expect(rows).toEqual([
      {
        employeeId: 'e1',
        orgId: 'o1',
        orgName: 'Shop',
        tenantSlug: 'shop-a',
        role: 'OWNER',
        isActive: true,
        archived: false,
        mustChangePassword: true,
        orgStatus: 'active',
        subscriptionEnd: '2027-01-01',
        timezone: 'Africa/Cairo',
      },
    ]);
  });
});

describe('countRecentFailures', () => {
  it('counts failures for the identifier and slug inside the window', async () => {
    mock.queue({ data: null, error: null, count: 3 } as never);
    await expect(countRecentFailures('owner.one', 'shop-a', 15)).resolves.toBe(3);
    expect(mock.from).toHaveBeenCalledWith('login_attempts');
    expect(mock.eq).toHaveBeenCalledWith('identifier', 'owner.one');
    expect(mock.eq).toHaveBeenCalledWith('success', false);
    expect(mock.eq).toHaveBeenCalledWith('tenant_slug', 'shop-a');
    const since = new Date(String(mock.gte.mock.calls[0]?.[1])).getTime();
    expect(Date.now() - since).toBeGreaterThanOrEqual(15 * 60_000 - 1000);
    expect(Date.now() - since).toBeLessThan(15 * 60_000 + 5000);
  });

  it('without a slug (email identifiers) it does not filter by shop', async () => {
    mock.queue({ data: null, error: null, count: 0 } as never);
    await countRecentFailures('a@b.co', null, 15);
    expect(mock.eq).not.toHaveBeenCalledWith('tenant_slug', expect.anything());
  });
});

describe('recordLoginAttempt', () => {
  it('inserts one row with ip and user agent', async () => {
    mock.queue({ data: null, error: null });
    await recordLoginAttempt({
      identifier: 'a@b.co',
      tenantSlug: null,
      success: false,
      ip: '203.0.113.1',
      userAgent: 'ua',
    });
    expect(mock.from).toHaveBeenCalledWith('login_attempts');
    expect(mock.insert).toHaveBeenCalledWith({
      identifier: 'a@b.co',
      tenant_slug: null,
      success: false,
      ip: '203.0.113.1',
      user_agent: 'ua',
    });
  });

  it('stores NULL for an ip that is not an address', async () => {
    mock.queue({ data: null, error: null });
    await recordLoginAttempt({
      identifier: 'a@b.co',
      tenantSlug: null,
      success: true,
      ip: 'unknown',
    });
    expect(mock.insert).toHaveBeenCalledWith(
      expect.objectContaining({ ip: null, user_agent: null }),
    );
  });

  it('a failed insert is an error (fail closed)', async () => {
    mock.queue({ data: null, error: { message: 'boom' } });
    await expect(
      recordLoginAttempt({ identifier: 'a', tenantSlug: null, success: true }),
    ).rejects.toMatchObject({
      statusCode: 500,
    });
  });
});

describe('clearMustChangePassword (D24)', () => {
  it('calls the service-role-only DB function with the verified auth user id', async () => {
    mock.queue({ data: 1, error: null });
    await clearMustChangePassword('u1');
    expect(mock.rpc).toHaveBeenCalledWith('auth_clear_must_change_password', {
      p_auth_user_id: 'u1',
    });
  });

  it('a database error becomes a generic 500', async () => {
    mock.queue({ data: null, error: { message: 'permission denied for function' } });
    await expect(clearMustChangePassword('u1')).rejects.toMatchObject({
      statusCode: 500,
      code: 'INTERNAL',
    });
  });
});
