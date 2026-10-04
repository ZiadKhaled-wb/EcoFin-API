import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { createLimiter } from './rateLimit';
import { requestId } from './requestId';

function appWith(trustProxy: number | false) {
  const app = express();
  app.set('trust proxy', trustProxy);
  app.use(requestId());
  app.use(createLimiter({ windowMs: 60_000, limit: 1 }));
  app.get('/ping', (_req, res) => {
    res.json({ ok: true });
  });
  return app;
}

describe('rate limiter behind a proxy', () => {
  it('trust proxy on: two X-Forwarded-For clients get separate buckets, and each is limited', async () => {
    const app = appWith(1);
    const a1 = await request(app).get('/ping').set('X-Forwarded-For', '203.0.113.1');
    const b1 = await request(app).get('/ping').set('X-Forwarded-For', '203.0.113.2');
    const a2 = await request(app).get('/ping').set('X-Forwarded-For', '203.0.113.1');
    expect(a1.status).toBe(200);
    expect(b1.status).toBe(200);
    expect(a2.status).toBe(429);
    expect(a2.body).toMatchObject({ error: { code: 'TOO_MANY_REQUESTS' } });
    expect(typeof (a2.body as { error: { requestId: string } }).error.requestId).toBe('string');
  });

  it('trust proxy off: X-Forwarded-For is ignored, so the clients share one bucket', async () => {
    const app = appWith(false);
    const a = await request(app).get('/ping').set('X-Forwarded-For', '203.0.113.1');
    const b = await request(app).get('/ping').set('X-Forwarded-For', '203.0.113.2');
    expect(a.status).toBe(200);
    expect(b.status).toBe(429);
  });
});

describe('login limiter key', () => {
  function loginApp() {
    const app = express();
    app.set('trust proxy', 1);
    app.use(requestId());
    app.use(express.json());
    app.use(createLimiter({ windowMs: 60_000, limit: 1 }));
    app.post('/login', (_req, res) => {
      res.json({ ok: true });
    });
    return app;
  }

  it('keys on IP + tenantSlug (the contract field): two shops behind one IP get separate buckets', async () => {
    const app = loginApp();
    const ip = '203.0.113.9';
    const shopA = await request(app)
      .post('/login')
      .set('X-Forwarded-For', ip)
      .send({ tenantSlug: 'shop-a' });
    const shopB = await request(app)
      .post('/login')
      .set('X-Forwarded-For', ip)
      .send({ tenantSlug: 'shop-b' });
    const shopAgain = await request(app)
      .post('/login')
      .set('X-Forwarded-For', ip)
      .send({ tenantSlug: 'shop-a' });
    expect(shopA.status).toBe(200);
    expect(shopB.status).toBe(200);
    expect(shopAgain.status).toBe(429);
  });

  it('the old tenant_slug field no longer splits the bucket', async () => {
    const app = loginApp();
    const ip = '203.0.113.10';
    await request(app).post('/login').set('X-Forwarded-For', ip).send({ tenant_slug: 'shop-a' });
    const other = await request(app)
      .post('/login')
      .set('X-Forwarded-For', ip)
      .send({ tenant_slug: 'shop-b' });
    expect(other.status).toBe(429);
  });
});
