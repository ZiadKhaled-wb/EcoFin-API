// F07: what the per-request DB client is built with. The IP is the one Express resolved behind
// trust proxy (one hop), never the raw X-Forwarded-For chain a client can forge.
import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { requestMeta } from './auth';
import type { RequestDevice } from './deviceContext';
import { requestId } from './requestId';

function appWithTrust(trust: number | false, device?: RequestDevice) {
  const app = express();
  app.set('trust proxy', trust);
  app.use(requestId());
  // What deviceContext leaves on the request once it resolved a device token.
  app.use((req, _res, next) => {
    req.device = device;
    next();
  });
  app.get('/meta', (req, res) => {
    res.json(requestMeta(req));
  });
  return app;
}

describe('requestMeta', () => {
  it('takes the IP Express resolved (the last proxy hop), not the forged start of the chain', async () => {
    const res = await request(appWithTrust(1))
      .get('/meta')
      .set('X-Forwarded-For', '6.6.6.6, 203.0.113.9');
    expect(res.body.ip).toBe('203.0.113.9');
  });

  it('ignores X-Forwarded-For entirely when no proxy is trusted', async () => {
    const res = await request(appWithTrust(false)).get('/meta').set('X-Forwarded-For', '6.6.6.6');
    expect(res.body.ip).not.toBe('6.6.6.6');
  });

  it('carries the request id and the user agent', async () => {
    const ok = await request(appWithTrust(1))
      .get('/meta')
      .set('x-request-id', 'req-abc')
      .set('user-agent', 'EcoFin-POS/1.0');
    expect(ok.body).toMatchObject({ requestId: 'req-abc', userAgent: 'EcoFin-POS/1.0' });
  });

  // O03 (D68): the device of a request is the one the API resolved from the device token.
  it('never carries a device id the client sent', async () => {
    const forged = await request(appWithTrust(1))
      .get('/meta')
      .set('x-device-id', '44444444-4444-4444-8444-444444444444')
      .set('x-device-token-hash', 'f'.repeat(64));
    expect(forged.body.deviceId).toBeUndefined();
    expect(forged.body.deviceTokenHash).toBeUndefined();
  });

  it('carries the resolved device, whatever device id the client sent', async () => {
    const device: RequestDevice = {
      id: '55555555-5555-4555-8555-555555555555',
      name: 'POS-1',
      branch_id: '66666666-6666-4666-8666-666666666666',
      branch_name: 'Main',
      tokenHash: 'a'.repeat(64),
    };
    const res = await request(appWithTrust(1, device))
      .get('/meta')
      .set('x-device-id', '44444444-4444-4444-8444-444444444444')
      .set('x-device-token-hash', 'f'.repeat(64));
    expect(res.body.deviceId).toBe(device.id);
    // With its proof: the hash of the token the API resolved, never one the client sent.
    expect(res.body.deviceTokenHash).toBe(device.tokenHash);
  });
});
