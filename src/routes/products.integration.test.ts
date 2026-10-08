// C02 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner creates a product with a generated barcode, the POS lookup finds it by
// that barcode, prices change for the owner but not for a branch manager whose
// catalog.price_change is overridden off, archive hides it from the lookup while the product
// stays readable, restore brings it back, and a cashier reads but never writes.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  Product,
  ProductList,
  ProductUnitList,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('C02 products against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let manager: string;
  let cashier: string;
  let org: string;
  let ip = 0;
  const call = (method: 'get' | 'post' | 'patch', path: string, token = owner, body?: object) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.13.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.13.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  async function addEmployee(role: 'CASHIER' | 'BRANCH_MANAGER', branchId: string) {
    const email = `c02.${role.toLowerCase()}.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email,
        full_name: role,
        role,
        default_branch_id: branchId,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branchId });
    return { email, id: emp.data!.id as string };
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `c02.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.13.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'C02 shop',
        tenant_slug: `c02-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.13.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    const c = await addEmployee('CASHIER', main.data!.id);
    cashier = await login(c.email);
    const m = await addEmployee('BRANCH_MANAGER', main.data!.id);
    const override = await service.from('employee_permission_overrides').insert({
      organization_id: org,
      employee_id: m.id,
      permission_key: 'catalog.price_change',
      granted: false,
    });
    expect(override.error).toBeNull();
    manager = await login(m.email);
  });

  it('create with a generated barcode, found by barcode, prices, archive, restore', async () => {
    const created = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون C02',
      name_en: 'C02 TV',
      sku: `c02-tv-${STAMP}`,
      cash_price: '15000.00',
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const product = Product.parse(created.body);
    expect(product.sku).toBe(`C02-TV-${STAMP}`);
    expect(product.barcode).toMatch(/^2\d{12}$/);
    expect(product.avg_cost).toBe('0.0000');
    expect(product.archived_at).toBeNull();

    // Done when: found by barcode in the POS.
    const found = await call('get', `/api/products/lookup?code=${product.barcode}`);
    expect(found.status, JSON.stringify(found.body)).toBe(200);
    expect(Product.parse(found.body).id).toBe(product.id);
    const bySku = await call('get', `/api/products/lookup?code=c02-tv-${STAMP}`);
    expect(Product.parse(bySku.body).id).toBe(product.id);

    const dup = await call('post', '/api/products', owner, {
      name_ar: 'x',
      sku: `C02-TV-${STAMP}`,
      cash_price: '1.00',
    });
    expect(dup.status).toBe(409);
    expect(code(dup)).toBe('PRODUCT_SKU_TAKEN');
    const cost = await call('post', '/api/products', owner, {
      name_ar: 'x',
      sku: `C02-X-${STAMP}`,
      cash_price: '1.00',
      avg_cost: '5',
    });
    expect(cost.status).toBe(400);

    // Prices: the owner may; the manager (catalog.price_change overridden off) may rename only.
    const priced = await call('patch', `/api/products/${product.id}`, owner, {
      cash_price: '14500.00',
      installment_price: '17000.00',
    });
    expect(priced.status, JSON.stringify(priced.body)).toBe(200);
    expect(Product.parse(priced.body)).toMatchObject({
      cash_price: '14500.00',
      installment_price: '17000.00',
    });
    const denied = await call('patch', `/api/products/${product.id}`, manager, {
      cash_price: '1.00',
    });
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    const renamed = await call('patch', `/api/products/${product.id}`, manager, {
      name_en: 'C02 TV 55',
    });
    expect(renamed.status, JSON.stringify(renamed.body)).toBe(200);
    const audit = await service
      .from('audit_log')
      .select('action, before, after')
      .eq('organization_id', org)
      .eq('entity_id', product.id)
      .order('id');
    expect(audit.data?.map((r) => r.action)).toEqual([
      'product.created',
      'product.price_changed',
      'product.updated',
    ]);
    expect(audit.data?.[1]?.before).toMatchObject({ cash_price: '15000.00' });
    expect(audit.data?.[1]?.after).toMatchObject({ cash_price: '14500.00' });

    // Archive: the POS no longer finds it, but the product stays readable.
    const archived = await call('post', `/api/products/${product.id}/archive`);
    expect(archived.status).toBe(200);
    expect(Product.parse(archived.body).archived_at).not.toBeNull();
    const gone = await call('get', `/api/products/lookup?code=${product.barcode}`);
    expect(gone.status).toBe(404);
    expect(code(gone)).toBe('PRODUCT_NOT_FOUND');
    const still = await call('get', `/api/products/${product.id}`);
    expect(still.status).toBe(200);
    expect(Product.parse(still.body).archived_at).not.toBeNull();
    const archivedList = ProductList.parse(
      (await call('get', '/api/products?status=archived')).body,
    );
    expect(archivedList.items.map((p) => p.id)).toEqual([product.id]);
    const noEdit = await call('patch', `/api/products/${product.id}`, owner, { name_en: 'x' });
    expect(noEdit.status).toBe(404);

    const restored = await call('post', `/api/products/${product.id}/restore`);
    expect(restored.status).toBe(200);
    expect(Product.parse(restored.body).archived_at).toBeNull();
    expect((await call('get', `/api/products/lookup?code=${product.barcode}`)).status).toBe(200);
  });

  it('lists with search, category filter and paging', async () => {
    const cat = await call('post', '/api/categories', owner, { name: `C02 Cat ${STAMP}` });
    expect(cat.status).toBe(201);
    const catId = (cat.body as { id: string }).id;
    for (const n of [1, 2, 3]) {
      const res = await call('post', '/api/products', owner, {
        name_ar: `C02 Item ${n}`,
        sku: `C02-ITEM-${n}-${STAMP}`,
        cash_price: '10.00',
        category_id: n === 1 ? catId : null,
      });
      expect(res.status, JSON.stringify(res.body)).toBe(201);
    }
    const page = ProductList.parse(
      (await call('get', '/api/products?search=C02%20Item&page=2&pageSize=2')).body,
    );
    expect(page).toMatchObject({ page: 2, pageSize: 2, total: 3 });
    expect(page.items).toHaveLength(1);
    const inCat = ProductList.parse((await call('get', `/api/products?category_id=${catId}`)).body);
    expect(inCat.items.map((p) => p.name_ar)).toEqual(['C02 Item 1']);
    const bad = await call('get', '/api/products?status=deleted');
    expect(bad.status).toBe(400);
  });

  it('a cashier reads the catalog but is refused every write', async () => {
    const list = await call('get', '/api/products', cashier);
    expect(list.status).toBe(200);
    const first = ProductList.parse(list.body).items[0]!;
    expect((await call('get', `/api/products/${first.id}`, cashier)).status).toBe(200);
    expect((await call('get', `/api/products/lookup?code=${first.sku}`, cashier)).status).toBe(200);
    const writes = [
      call('post', '/api/products', cashier, { name_ar: 'x', sku: 'C02-CASH', cash_price: '1.00' }),
      call('patch', `/api/products/${first.id}`, cashier, { name_en: 'x' }),
      call('post', `/api/products/${first.id}/archive`, cashier),
      call('post', `/api/products/${first.id}/restore`, cashier),
    ];
    for (const res of await Promise.all(writes)) {
      expect(res.status).toBe(403);
      expect(code(res)).toBe('PERMISSION_DENIED');
    }
  });

  it('C03: lists a serialized product units (serials) for labels', async () => {
    const created = await call('post', '/api/products', owner, {
      name_ar: 'موبايل C02',
      sku: `C03-PH-${STAMP}`,
      cash_price: '9000.00',
      is_serialized: true,
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const phone = Product.parse(created.body);
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    const units = await service.from('units').insert([
      {
        organization_id: org,
        product_id: phone.id,
        serial: `IMEI-${STAMP}-2`,
        branch_id: main.data!.id,
        cost: 1,
      },
      {
        organization_id: org,
        product_id: phone.id,
        serial: `IMEI-${STAMP}-1`,
        branch_id: main.data!.id,
        cost: 1,
      },
    ]);
    expect(units.error).toBeNull();
    const res = await call('get', `/api/products/${phone.id}/units`, cashier);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(ProductUnitList.parse(res.body).map((u) => u.serial)).toEqual([
      `IMEI-${STAMP}-1`,
      `IMEI-${STAMP}-2`,
    ]);
    const sold = await call('get', `/api/products/${phone.id}/units?status=sold`);
    expect(ProductUnitList.parse(sold.body)).toEqual([]);
    expect((await call('get', `/api/products/${phone.id}/units?status=lost`)).status).toBe(400);
  });
});
