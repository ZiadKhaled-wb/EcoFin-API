import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { AuthLoginResponse, Quotation, QuotationCreated } from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
const RUN = process.env['RUN_INTEGRATION'] === '1';
describe.skipIf(!RUN)('S09 local API', () => {
  let app: ReturnType<typeof createApp>, a: string, b: string, id: string, customer: string;
  const orgA = 'd1000000-0000-0000-0000-000000000001',
    orgB = 'd1000000-0000-0000-0000-000000000002';
  const branch = 'd2000000-0000-0000-0000-000000000011';
  const body = {
    branch_id: branch,
    lines: [
      {
        description: 'S09 custom',
        quantity: 2,
        unit_price: '114.00',
        discount_amount: '0',
        tax_amount: '999',
        line_total: '999',
      },
    ],
    total: '999',
  };
  function call(method: 'get' | 'post' | 'put', path: string, token = a, org = orgA) {
    return request(app)
      [method](path)
      .set('Authorization', 'Bearer ' + token)
      .set('x-org-id', org);
  }
  beforeAll(async () => {
    app = createApp({ env: getEnv() });
    const login = async (identifier: string) =>
      AuthLoginResponse.parse(
        (
          await request(app)
            .post('/api/auth/login')
            .send({ identifier, password: 'LocalDev-Only-2026!' })
        ).body,
      ).accessToken;
    a = await login('owner.one@ecotech.test');
    b = await login('owner.two@ecotech.test');
    const r = await call('post', '/api/customers').send({
      full_name: 'S09 API customer',
      phones: ['01012345678'],
    });
    expect(r.status).toBe(201);
    customer = (r.body as { id: string }).id;
  });
  it('A1/A4 creates, updates, sends and accepts with frozen server totals', async () => {
    const r = await call('post', '/api/quotations')
      .set('Idempotency-Key', 's09-api-' + Date.now())
      .send({ ...body, customer_id: customer });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    id = QuotationCreated.parse(r.body).id;
    const q = Quotation.parse((await call('get', '/api/quotations/' + id)).body);
    expect(q.total).not.toBe('999');
    expect(q.lines[0]?.tax_amount).not.toBe('999');
    const u = await call('put', '/api/quotations/' + id).send({
      ...body,
      customer_id: customer,
      expected_updated_at: q.updated_at,
    });
    expect(u.status).toBe(200);
    expect((await call('post', '/api/quotations/' + id + '/send')).status).toBe(200);
    const accepted = Quotation.parse(
      (await call('post', '/api/quotations/' + id + '/accept')).body,
    );
    expect(accepted.status).toBe('accepted');
    expect(accepted.lines).toEqual(Quotation.parse(u.body).lines);
    expect(accepted.total).toBe(q.total);
  });
  it('A2 another shop cannot get or change a quote and its list excludes it', async () => {
    for (const [method, suffix] of [
      ['get', ''],
      ['put', ''],
      ['post', '/send'],
      ['post', '/accept'],
      ['post', '/reject'],
      ['post', '/cancel'],
    ] as const) {
      const r = await call(method, '/api/quotations/' + id + suffix, b, orgB).send({
        ...body,
        reason: 'Declined',
        expected_updated_at: new Date().toISOString(),
      });
      expect(r.status, JSON.stringify(r.body)).toBe(404);
    }
    const r = await call('get', '/api/quotations', b, orgB);
    expect(JSON.stringify(r.body)).not.toContain(id);
  });
  it('A3 returns name/phone and never national ID', async () => {
    const r = await call('get', '/api/quotations/' + id);
    expect(r.status).toBe(200);
    expect(Quotation.parse(r.body).customer).toMatchObject({
      name: 'S09 API customer',
      phone: '01012345678',
    });
    expect(JSON.stringify(r.body)).not.toContain('national_id');
  });
});
