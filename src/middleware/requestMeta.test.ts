// F07: what the per-request DB client is built with. The IP is the one Express resolved behind
// trust proxy (one hop), never the raw X-Forwarded-For chain a client can forge.
import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { requestMeta } from './auth';
import { requestId } from './requestId';

function appWithTrust(trust: number | false) {
  const app = express();
  app.set('trust proxy', trust);
  app.use(requestId());
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

  it('carries the request id, the user agent and a valid device id only', async () => {
    const device = '44444444-4444-4444-8444-444444444444';
    const ok = await request(appWithTrust(1))
      .get('/meta')
      .set('x-request-id', 'req-abc')
      .set('user-agent', 'EcoFin-POS/1.0')
      .set('x-device-id', device);
    expect(ok.body).toMatchObject({
      requestId: 'req-abc',
      userAgent: 'EcoFin-POS/1.0',
      deviceId: device,
    });
    const bad = await request(appWithTrust(1)).get('/meta').set('x-device-id', 'drop table x');
    expect(bad.body.deviceId).toBeUndefined();
  });
});
