// INT-4: the fake ETA process answers on its own port with the seed's credentials, and its admin
// controls reach the fake (Invalid next, a fault, the counts).
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { INT4_FAKE_ETA, startFakeEtaProcess, type FakeEtaProcess } from './fake-eta-server';

describe('fake ETA process (INT-4 tooling)', () => {
  let running: FakeEtaProcess;
  beforeAll(async () => {
    running = await startFakeEtaProcess({ eta: 0, admin: 0 });
  });
  afterAll(() => running.close());

  const token = (serial: string, key: string) =>
    fetch(`${running.fake.url}/connect/token`, {
      method: 'POST',
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
        posserial: serial,
        presharedkey: key,
        pososversion: 'os',
        posmodelframework: '1',
      },
      body: new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: INT4_FAKE_ETA.clientId,
        client_secret: INT4_FAKE_ETA.clientSecret,
      }),
    });

  it('binds both ports to 127.0.0.1', () => {
    expect(running.fake.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
    expect(running.adminUrl).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
  });

  it('accepts both INT-4 POS devices and refuses an unknown one', async () => {
    expect((await token('INT4-POS-1', 'int4-fake-psk-1')).status).toBe(200);
    expect((await token('INT4-POS-2', 'int4-fake-psk-2')).status).toBe(200);
    expect((await token('INT4-POS-2', 'int4-fake-psk-1')).status).toBe(400);
    expect((await token('OTHER', 'int4-fake-psk-1')).status).toBe(400);
  });

  it('exposes the controls and the counts', async () => {
    const post = (path: string, body: object) =>
      fetch(`${running.adminUrl}${path}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
    expect((await post('/admin/invalid-next', { message: 'bad item', code: 'CV307' })).status).toBe(
      204,
    );
    expect((await post('/admin/invalid-next', {})).status).toBe(400);
    expect((await post('/admin/fail-next', { fault: 'duplicate', retryAfter: 1 })).status).toBe(
      204,
    );
    expect((await post('/admin/fail-next', { fault: 'explode' })).status).toBe(400);
    const state = (await (await fetch(`${running.adminUrl}/admin/state`)).json()) as {
      received: Record<string, number>;
      calls: { token: number };
    };
    expect(state.received).toEqual({});
    expect(state.calls.token).toBeGreaterThanOrEqual(4);
  });
});
