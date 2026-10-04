import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { noClientOrg, findOrgKey } from './noClientOrg';
import { errorHandler } from './errorHandler';

const ORG = '11111111-1111-4111-8111-111111111111';

const app = express();
app.use(express.json());
app.use(noClientOrg);
app.all('*', (_req, res) => {
  res.json({ ok: true });
});
app.use(errorHandler);

describe('noClientOrg', () => {
  it.each([
    ['organization_id', { organization_id: ORG }],
    ['organizationId', { organizationId: ORG }],
    ['orgId', { orgId: ORG }],
    ['ORG-ID', { 'ORG-ID': ORG }],
    ['nested', { lines: [{ productId: 'p', organization_id: ORG }] }],
  ])('body with %s -> 400 VALIDATION_FAILED', async (_name, body) => {
    const res = await request(app).post('/api/anything').send(body);
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_FAILED');
  });

  it.each(['organization_id', 'organizationId', 'orgId'])(
    'query with %s -> 400 VALIDATION_FAILED',
    async (key) => {
      const res = await request(app).get(`/api/anything?${key}=${ORG}`);
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('VALIDATION_FAILED');
    },
  );

  it('a normal request passes', async () => {
    const res = await request(app).post('/api/anything?branchId=x').send({ name: 'Sofa' });
    expect(res.status).toBe(200);
  });

  it('select-shop may send orgId in the body (D23), but nothing else org-like', async () => {
    expect((await request(app).post('/api/auth/select-shop').send({ orgId: ORG })).status).toBe(
      200,
    );
    const res = await request(app)
      .post('/api/auth/select-shop')
      .send({ orgId: ORG, organization_id: ORG });
    expect(res.status).toBe(400);
    expect(
      (await request(app).post(`/api/auth/select-shop?orgId=${ORG}`).send({ orgId: ORG })).status,
    ).toBe(400);
  });

  it('the orgId exception is only for select-shop', async () => {
    expect((await request(app).post('/api/auth/me').send({ orgId: ORG })).status).toBe(400);
  });

  it('findOrgKey names the path', () => {
    expect(findOrgKey({ a: [{ organizationId: 1 }] }, 'body')).toBe('body.a.0.organizationId');
    expect(findOrgKey({ a: 1 }, 'body')).toBeUndefined();
  });
});
