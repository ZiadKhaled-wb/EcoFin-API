import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  StockList,
  WarrantyLookupResponse,
  WarrantyClaim,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('S12 sale core against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let org: string;
  let branch: string;
  let chair: string;
  let phone: string;
  let unit: string;
  let replacement: string;
  let claimId: string;
  let plainLine: string;
  let ip = 0;
  // O03: the paired POS computer every request of this test comes from.
  let pos = '';
  const call = (
    method: 'get' | 'post',
    path: string,
    token = cashier,
    body?: object,
    key?: string,
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.79.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    if (pos) r.set(DEVICE_TOKEN_HEADER, pos);
    if (key) r.set('Idempotency-Key', key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.79.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const key = (tag: string) => `s12-it-${tag}-${STAMP}`;

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `s12.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.79.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'S12 shop',
        tenant_slug: `s12-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.79.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service
      .from('branches')
      .select('id, default_cash_account_id')
      .eq('organization_id', org)
      .single();
    expect(main.error).toBeNull();
    branch = main.data!.id as string;
    pos = (await pairTestDevice(service, org, branch)).token;
    const cashierEmail = `s12.cashier.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email: cashierEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email: cashierEmail,
        full_name: 'Mona Cashier',
        role: 'CASHIER',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    cashier = await login(cashierEmail);

    // The shop sells at prices that include VAT (the default), 14% on both products.
    const p1 = await call('post', '/api/products', owner, {
      name_ar: 'كرسي',
      sku: 'S12-CH',
      cash_price: '250.00',
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    chair = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', owner, {
      name_ar: 'هاتف',
      sku: 'S12-PH',
      cash_price: '5000.00',
      is_serialized: true,
      warranty_months: 12,
    });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    phone = (p2.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: chair, quantity: 5 }] },
      key('stock'),
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const units = await call(
      'post',
      '/api/units',
      owner,
      {
        product_id: phone,
        branch_id: branch,
        cost: '3000.00',
        serials: [`S12-${STAMP}`, `S12-B-${STAMP}`, `S12-C-${STAMP}`],
      },
      key('units'),
    );
    expect(units.status, JSON.stringify(units.body)).toBe(201);
    unit = (units.body as { units: { id: string }[] }).units[0]!.id;
    replacement = (units.body as { units: { id: string }[] }).units[1]!.id;
  }, 60_000);

  it('serialized sale, cashier photo, replacement and new serial retain the full history', async () => {
    const shift = await call(
      'post',
      '/api/shifts',
      cashier,
      { branch_id: branch, opening_float: '0.00' },
      key('shift'),
    );
    expect(shift.status, JSON.stringify(shift.body)).toBe(201);
    const lines = [
      { product_id: chair, quantity: 2 },
      { product_id: phone, quantity: 1, unit_id: unit },
    ];
    const quote = await call('post', '/api/sales/quote', cashier, { lines });
    expect(quote.status, JSON.stringify(quote.body)).toBe(200);
    const sale = await call(
      'post',
      '/api/sales',
      cashier,
      { lines, expected_total: quote.body.total },
      key('sale'),
    );
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
    const lookup = await call('get', '/api/warranty/lookup?serial=S12-' + STAMP);
    expect(lookup.status, JSON.stringify(lookup.body)).toBe(200);
    const line = WarrantyLookupResponse.parse(lookup.body).items[0]!;
    expect(line.warranty_until).toBe(
      new Date(
        new Date(line.sale_date + 'T00:00:00Z').setUTCFullYear(
          Number(line.sale_date.slice(0, 4)) + 1,
        ) - 86400000,
      )
        .toISOString()
        .slice(0, 10),
    );
    const opened = await call(
      'post',
      '/api/warranty/claims',
      cashier,
      {
        sale_line_id: line.sale_line_id,
        unit_id: unit,
        issue: 'Screen failed',
        condition: 'Scratched case',
      },
      key('claim'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    claimId = opened.body.claim_id;
    const retry = await call(
      'post',
      '/api/warranty/claims',
      cashier,
      {
        sale_line_id: line.sale_line_id,
        unit_id: unit,
        issue: 'Screen failed',
        condition: 'Scratched case',
      },
      key('claim'),
    );
    expect(retry.body).toEqual(opened.body);
    const photo = await request(app)
      .post('/api/files')
      .set('X-Forwarded-For', '198.18.79.220')
      .set('Authorization', 'Bearer ' + cashier)
      .set('x-org-id', org)
      .field('purpose', 'other')
      .field('entityType', 'warranty_claim')
      .field('entityId', claimId)
      .attach(
        'file',
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...Array(64).fill(7)]),
        'claim.png',
      );
    expect(photo.status, JSON.stringify(photo.body)).toBe(201);
    const url = await call('get', '/api/files/' + photo.body.id + '/url');
    expect(url.status, JSON.stringify(url.body)).toBe(200);
    expect(url.body.url).toContain('token=');
    const moved = await call('post', '/api/warranty/claims/' + claimId + '/move', cashier, {
      to: 'replaced',
      note: 'Replace faulty unit',
      replacement_unit_id: replacement,
    });
    expect(moved.status, JSON.stringify(moved.body)).toBe(200);
    const c = WarrantyClaim.parse(moved.body);
    expect(c.status).toBe('replaced');
    expect(c.files).toHaveLength(1);
    expect(c.line.chain.map((u) => u.serial)).toEqual(['S12-' + STAMP, 'S12-B-' + STAMP]);
    const again = await call('post', '/api/warranty/claims/' + claimId + '/move', cashier, {
      to: 'replaced',
      note: 'Replace faulty unit',
      replacement_unit_id: replacement,
    });
    expect(again.status).toBe(200);
    const byB = await call('get', '/api/warranty/lookup?serial=S12-B-' + STAMP);
    const byA = await call('get', '/api/warranty/lookup?serial=S12-' + STAMP);
    expect(byB.body).toEqual(byA.body);
    const levels = await call('get', '/api/stock?branch_id=' + branch, owner);
    const stock = StockList.parse(levels.body);
    expect(stock.items.find((p) => p.product_id === phone)?.on_hand).toBe(1);
    const detail = await call('get', '/api/units/' + replacement, owner);
    expect(detail.body.status).toBe('sold');
    const refund = await call('post', '/api/warranty/claims/' + claimId + '/refund');
    expect(refund.status).toBe(409);
    expect(code(refund)).toBe('CLAIM_REFUND_NEEDS_RETURN');
    const receipt = await call(
      'get',
      '/api/warranty/lookup?sale_number=' + encodeURIComponent(line.sale_number),
    );
    plainLine = WarrantyLookupResponse.parse(receipt.body).items.find(
      (l) => l.product.id === chair,
    )!.sale_line_id;
  });
  it('out-of-warranty cashier gets 403 but may reject; list filters work', async () => {
    const opened = await call(
      'post',
      '/api/warranty/claims',
      cashier,
      { sale_line_id: plainLine, issue: 'Chair broken', condition: 'Used chair' },
      key('expired'),
    );
    expect(opened.status, JSON.stringify(opened.body)).toBe(201);
    expect(opened.body.out_of_warranty).toBe(true);
    const move = await call(
      'post',
      '/api/warranty/claims/' + opened.body.claim_id + '/move',
      cashier,
      { to: 'in_repair', note: 'Repair' },
    );
    expect(move.status).toBe(403);
    expect(code(move)).toBe('OUT_OF_WARRANTY_NEEDS_MANAGER');
    const rows = await call('get', '/api/warranty/claims?out_of_warranty=true');
    expect(rows.body.items.some((c: { id: string }) => c.id === opened.body.claim_id)).toBe(true);
    const reject = await call(
      'post',
      '/api/warranty/claims/' + opened.body.claim_id + '/move',
      cashier,
      { to: 'rejected', note: 'Not covered' },
    );
    expect(reject.status).toBe(200);
  });
  it('foreign claim is 404; invalid lookup and missing key fail before writes', async () => {
    const other = await login('owner.two@ecotech.test');
    const detail = await request(app)
      .get('/api/warranty/claims/' + claimId)
      .set('X-Forwarded-For', '198.18.79.221')
      .set('Authorization', 'Bearer ' + other);
    expect(detail.status).toBe(404);
    expect(code(detail)).toBe('NOT_FOUND');
    const lookup = await call('get', '/api/warranty/lookup?serial=A&phone=010');
    expect(lookup.status).toBe(400);
    expect(code(lookup)).toBe('LOOKUP_ONE_KEY');
    const missing = await call('post', '/api/warranty/claims', cashier, {
      sale_line_id: plainLine,
      issue: 'Broken',
      condition: 'Scratched',
    });
    expect(missing.status).toBe(400);
  });
});
