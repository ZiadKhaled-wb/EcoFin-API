// I04 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts), with the seed
// shop one (its plan has the serials module): serials registered through the API, a duplicate
// refused with the serial named, the unit found by serial with its history after a transfer, and
// the search (permission denials are in the SQL suites and the route markers).
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import {
  AuthLoginResponse,
  ErrorResponse,
  Product,
  UnitDetail,
  UnitList,
  UnitRegistration,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const SHOP_ONE = 'd1000000-0000-0000-0000-000000000001';
const BR1 = 'd2000000-0000-0000-0000-000000000011';
const BR2 = 'd2000000-0000-0000-0000-000000000012';

describe.skipIf(!RUN)('I04 serial units against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let owner: string;
  let ip = 0;
  const nextIp = () => `198.18.15.${(++ip % 250) + 1}`;
  const call = (
    method: 'get' | 'post',
    path: string,
    token: string,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + token)
      .set('x-org-id', SHOP_ONE);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }

  beforeAll(async () => {
    app = createApp({ env: getEnv() });
    owner = await login('owner.one@ecotech.test');
  });

  it('registers serials, refuses a duplicate, and shows a unit with its history', async () => {
    const made = await call('post', '/api/products', owner, {
      name_ar: 'موبايل I04',
      sku: `I04-PH-${STAMP}`,
      cash_price: '9000.00',
      is_serialized: true,
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    const product = Product.parse(made.body);
    const serials = [`i04-${STAMP}-a`, `I04-${STAMP}-B`];
    const body = { product_id: product.id, branch_id: BR1, cost: '7000.50', serials };

    expect((await call('post', '/api/units', owner, body)).status).toBe(400); // no key
    const reg = await call('post', '/api/units', owner, body, `i04-reg-${STAMP}`);
    expect(reg.status, JSON.stringify(reg.body)).toBe(201);
    const batch = UnitRegistration.parse(reg.body);
    expect(batch.units.map((u) => u.serial)).toEqual([`I04-${STAMP}-A`, `I04-${STAMP}-B`]);
    const again = await call('post', '/api/units', owner, body, `i04-reg-${STAMP}`);
    expect(UnitRegistration.parse(again.body).import_job_id).toBe(batch.import_job_id);

    // Done when: a duplicate serial is rejected, and the error names it.
    const dup = await call(
      'post',
      '/api/units',
      owner,
      { ...body, serials: [`I04-${STAMP}-a`.toLowerCase(), `I04-${STAMP}-C`] },
      `i04-dup-${STAMP}`,
    );
    expect(dup.status).toBe(409);
    expect(ErrorResponse.parse(dup.body).error).toMatchObject({
      code: 'SERIAL_TAKEN',
      details: { serials: [`I04-${STAMP}-A`] },
    });

    // Move one unit to BR2 (I03): the history shows it.
    const unitA = batch.units[0]!;
    const tr = await call(
      'post',
      '/api/stock/transfers',
      owner,
      {
        from_branch_id: BR1,
        to_branch_id: BR2,
        lines: [{ product_id: product.id, unit_id: unitA.id, quantity: 1 }],
      },
      `i04-tr-${STAMP}`,
    );
    expect(tr.status, JSON.stringify(tr.body)).toBe(201);
    const id = tr.body.id as string;
    expect((await call('post', `/api/stock/transfers/${id}/send`, owner, {})).status).toBe(200);
    expect((await call('post', `/api/stock/transfers/${id}/receive`, owner, {})).status).toBe(200);

    const found = await call(
      'get',
      `/api/units/find?serial=${encodeURIComponent(` i04-${STAMP}-a `)}`,
      owner,
    );
    expect(found.status, JSON.stringify(found.body)).toBe(200);
    const unit = UnitDetail.parse(found.body);
    expect(unit).toMatchObject({
      id: unitA.id,
      status: 'in_stock',
      branch_id: BR2,
      cost: '7000.50',
    });
    expect(unit.history.map((h) => [h.type, h.quantity, h.branch_id])).toEqual([
      ['opening', 1, BR1],
      ['transfer_out', -1, BR1],
      ['transfer_in', 1, BR2],
    ]);
    expect(unit.history[1]?.source_number).toBe(tr.body.number);

    const search = UnitList.parse(
      (await call('get', `/api/units?search=I04-${STAMP}`, owner)).body,
    );
    expect(search.items.map((u) => [u.serial, u.branch_id])).toEqual([
      [`I04-${STAMP}-A`, BR2],
      [`I04-${STAMP}-B`, BR1],
    ]);
    expect((await call('get', `/api/units/${unitA.id}`, owner)).status).toBe(200);
    expect((await call('get', '/api/units/find', owner)).status).toBe(400);
  });
});
