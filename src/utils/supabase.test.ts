// Per-request clients: no client is shared between requests, none persists a session.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

const created = vi.hoisted(() => ({
  calls: [] as { url: string; key: string; options: Record<string, unknown> }[],
}));

vi.mock('@supabase/supabase-js', () => ({
  createClient: vi.fn((url: string, key: string, options: Record<string, unknown>) => {
    const client = { url, key, options };
    created.calls.push(client);
    return client;
  }),
}));

import { createAuthClient, supabaseForRequest, updatePasswordWithToken } from './supabase';

beforeEach(() => {
  created.calls = [];
});
afterEach(() => {
  vi.unstubAllGlobals();
});

describe('supabaseForRequest', () => {
  it('two JWTs give two different clients, each with only its own token', () => {
    const a = supabaseForRequest('jwt-a');
    const b = supabaseForRequest('jwt-b', '33333333-3333-4333-8333-333333333333');
    expect(a).not.toBe(b);
    const [ca, cb] = created.calls;
    expect(ca?.options['global']).toEqual({ headers: { Authorization: 'Bearer jwt-a' } });
    expect(cb?.options['global']).toEqual({
      headers: {
        Authorization: 'Bearer jwt-b',
        'x-org-id': '33333333-3333-4333-8333-333333333333',
      },
    });
  });

  it('uses the anon key (never the service role) and never stores or refreshes a session', () => {
    supabaseForRequest('jwt-a');
    const call = created.calls[0];
    expect(call?.key).toBe(process.env['SUPABASE_ANON_KEY']);
    expect(call?.options['auth']).toMatchObject({ persistSession: false, autoRefreshToken: false });
  });

  it('refuses an empty token instead of falling back to anon', () => {
    expect(() => supabaseForRequest('')).toThrow();
  });

  // F07: app.write_audit reads these headers for every audit row.
  it('forwards request id, resolved IP, user agent and the resolved device id', () => {
    const device = '44444444-4444-4444-8444-44444444ABCD';
    supabaseForRequest('jwt-a', undefined, {
      ip: '203.0.113.9',
      userAgent: 'Mozilla/5.0 test',
      requestId: 'req-123',
      deviceId: device,
      deviceTokenHash: 'a'.repeat(64),
    });
    expect(created.calls[0]?.options['global']).toEqual({
      headers: {
        Authorization: 'Bearer jwt-a',
        'x-forwarded-for': '203.0.113.9',
        'user-agent': 'Mozilla/5.0 test',
        'x-request-id': 'req-123',
        'x-device-id': device.toLowerCase(),
        'x-device-token-hash': 'a'.repeat(64),
      },
    });
  });

  // O03: the database counts a device only with the hash of its token.
  it.each([[undefined], ['not-a-hash'], ['A'.repeat(64)], ['a'.repeat(63)]])(
    'never forwards a device id without the hash of its token (%s)',
    (deviceTokenHash) => {
      supabaseForRequest('jwt-a', undefined, {
        deviceId: '44444444-4444-4444-8444-444444444444',
        deviceTokenHash,
      });
      const headers = (created.calls[0]?.options['global'] as { headers: Record<string, string> })
        .headers;
      expect(headers).not.toHaveProperty('x-device-id');
      expect(headers).not.toHaveProperty('x-device-token-hash');
    },
  );

  it.each([['not-a-uuid'], ['44444444-4444-4444-8444-444444444444, 55555555'], ['']])(
    'never forwards an invalid device id (%s)',
    (deviceId) => {
      supabaseForRequest('jwt-a', undefined, { deviceId, deviceTokenHash: 'a'.repeat(64) });
      const headers = (created.calls[0]?.options['global'] as { headers: Record<string, string> })
        .headers;
      expect(headers).not.toHaveProperty('x-device-id');
    },
  );
});

describe('createAuthClient', () => {
  it('returns a new anon client every call', () => {
    const a = createAuthClient();
    const b = createAuthClient();
    expect(a).not.toBe(b);
    expect(created.calls.map((c) => c.key)).toEqual([
      process.env['SUPABASE_ANON_KEY'],
      process.env['SUPABASE_ANON_KEY'],
    ]);
    expect(created.calls[0]?.options['auth']).toMatchObject({
      persistSession: false,
      flowType: 'implicit',
    });
  });
});

describe('updatePasswordWithToken', () => {
  it('PUTs the password to GoTrue /user with the caller token', async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    await expect(updatePasswordWithToken('jwt-a', 'New-Pass-2026!')).resolves.toEqual({
      ok: true,
      status: 200,
    });
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe(`${process.env['SUPABASE_URL']}/auth/v1/user`);
    expect(init.method).toBe('PUT');
    expect(init.headers).toMatchObject({ Authorization: 'Bearer jwt-a' });
    expect(JSON.parse(String(init.body))).toEqual({ password: 'New-Pass-2026!' });
  });

  it('returns only the status and GoTrue error code on failure', async () => {
    vi.stubGlobal(
      'fetch',
      vi
        .fn()
        .mockResolvedValue(
          new Response(
            JSON.stringify({ code: 422, error_code: 'same_password', msg: 'raw message' }),
            { status: 422 },
          ),
        ),
    );
    await expect(updatePasswordWithToken('jwt-a', 'x')).resolves.toEqual({
      ok: false,
      status: 422,
      code: 'same_password',
    });
  });
});
