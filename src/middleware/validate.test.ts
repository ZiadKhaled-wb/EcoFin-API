import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { z } from 'zod';
import { AuthSelectShopBody, PaginationQuery } from '@ziadkhaled-wb/contracts';
import { validate } from './validate';
import { errorHandler } from './errorHandler';

const ORG = '11111111-1111-4111-8111-111111111111';

const app = express();
app.use(express.json());
const echo: express.RequestHandler = (req, res) => {
  res.json({ body: req.body as unknown, query: req.query, params: req.params });
};
app.post('/items', validate({ body: z.object({ name: z.string() }).strict() }), echo);
app.get('/items', validate({ query: PaginationQuery.strict() }), echo);
app.get('/items/:id', validate({ params: z.object({ id: z.string().uuid() }).strict() }), echo);
app.get('/shops/:orgId', validate({ params: z.object({ orgId: z.string() }).strict() }), echo);
app.post('/select', validate({ body: AuthSelectShopBody }), echo);
app.post('/nothing', validate(), echo);
app.use(errorHandler);

const code = (res: request.Response) => (res.body as { error: { code: string } }).error.code;

describe('validate', () => {
  it('passes the parsed body to the handler', async () => {
    const res = await request(app).post('/items').send({ name: 'Sofa' });
    expect(res.status).toBe(200);
    expect(res.body.body).toEqual({ name: 'Sofa' });
  });

  it('an unknown body key -> 400 VALIDATION_FAILED', async () => {
    const res = await request(app).post('/items').send({ name: 'Sofa', price: '10.00' });
    expect(res.status).toBe(400);
    expect(code(res)).toBe('VALIDATION_FAILED');
  });

  it('a wrong body type -> 400 VALIDATION_FAILED', async () => {
    const res = await request(app).post('/items').send({ name: 3 });
    expect(res.status).toBe(400);
    expect(code(res)).toBe('VALIDATION_FAILED');
  });

  it('organization_id in the body is an unknown key -> 400', async () => {
    const res = await request(app).post('/items').send({ name: 'Sofa', organization_id: ORG });
    expect(res.status).toBe(400);
    expect(code(res)).toBe('VALIDATION_FAILED');
  });

  it('parses the query (coerced, defaults filled) and refuses unknown query keys', async () => {
    const ok = await request(app).get('/items?page=2');
    expect(ok.status).toBe(200);
    expect(ok.body.query).toEqual({ page: 2, pageSize: 50 });
    const bad = await request(app).get('/items?page=2&sort=name');
    expect(bad.status).toBe(400);
    expect(code(bad)).toBe('VALIDATION_FAILED');
  });

  it('parses params', async () => {
    expect((await request(app).get(`/items/${ORG}`)).status).toBe(200);
    const bad = await request(app).get('/items/not-a-uuid');
    expect(bad.status).toBe(400);
    expect(code(bad)).toBe('VALIDATION_FAILED');
  });

  it('an org key in route params -> 400, even when the schema would allow it', async () => {
    const res = await request(app).get(`/shops/${ORG}`);
    expect(res.status).toBe(400);
    expect(code(res)).toBe('VALIDATION_FAILED');
    expect(res.body.error.details).toEqual({ path: 'params.orgId' });
  });

  it('works with contract schemas (their own zod copy)', async () => {
    expect((await request(app).post('/select').send({ orgId: ORG })).status).toBe(200);
    const res = await request(app).post('/select').send({ orgId: ORG, role: 'OWNER' });
    expect(res.status).toBe(400);
    expect(code(res)).toBe('VALIDATION_FAILED');
  });

  it('a route without schemas takes no body and no query', async () => {
    expect((await request(app).post('/nothing')).status).toBe(200);
    expect((await request(app).post('/nothing').send({})).status).toBe(200);
    expect((await request(app).post('/nothing').send({ x: 1 })).status).toBe(400);
    expect((await request(app).post('/nothing?x=1')).status).toBe(400);
  });
});
