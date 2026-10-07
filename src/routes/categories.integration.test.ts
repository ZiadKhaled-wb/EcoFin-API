// C01 against local Supabase (RUN_INTEGRATION=1, env as in auth.integration.test.ts):
// a fresh shop's owner creates, renames, nests and archives categories (with the
// active-product move), the cashier reads the list and is refused every write.
import { beforeAll, describe, it, expect } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuthLoginResponse, Category, CategoryList, ErrorResponse } from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();

describe.skipIf(!RUN)('C01 categories against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let owner: string;
  let cashier: string;
  let org: string;
  let ip = 0;
  const call = (method: 'get' | 'post' | 'patch', path: string, token = owner, body?: object) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.12.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    if (org) r.set('x-org-id', org);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.12.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }

  beforeAll(async () => {
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = await login('superadmin@ecotech.test');
    const email = `c01.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.12.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'C01 shop',
        tenant_slug: `c01-${STAMP}`,
        plan_key: 'retail',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.12.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
    const cashierEmail = `c01.cashier.${STAMP}@ecotech.test`;
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
        full_name: 'Cashier',
        role: 'CASHIER',
        default_branch_id: main.data!.id,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: main.data!.id });
    cashier = await login(cashierEmail);
  });

  it('the owner manages categories: create, nest, rename, top-level again', async () => {
    const empty = CategoryList.parse((await call('get', '/api/categories')).body);
    expect(empty).toEqual([]);

    const created = await call('post', '/api/categories', owner, {
      name: `C01 A Parent ${STAMP}`,
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const parent = Category.parse(created.body);
    expect(parent.parent_id).toBeNull();
    expect(parent.archived_at).toBeNull();
    expect(parent.active_product_count).toBe(0);

    const childRes = await call('post', '/api/categories', owner, {
      name: 'C01 A Child',
      parent_id: parent.id,
    });
    expect(childRes.status, JSON.stringify(childRes.body)).toBe(201);
    const child = Category.parse(childRes.body);
    expect(child.parent_id).toBe(parent.id);

    const otherRes = await call('post', '/api/categories', owner, {
      name: `C01 Z Other ${STAMP}`,
    });
    expect(otherRes.status).toBe(201);
    const other = Category.parse(otherRes.body);
    expect(other.parent_id).toBeNull();

    // Active first, parents in name order, each followed by its children.
    const list = CategoryList.parse((await call('get', '/api/categories')).body);
    expect(list.map((c) => c.id)).toEqual([parent.id, child.id, other.id]);

    const renamed = await call('patch', `/api/categories/${parent.id}`, owner, {
      name: `C01 B Parent ${STAMP}`,
    });
    expect(renamed.status).toBe(200);
    expect(Category.parse(renamed.body).name).toBe(`C01 B Parent ${STAMP}`);

    const topLevel = await call('patch', `/api/categories/${child.id}`, owner, {
      parent_id: null,
    });
    expect(Category.parse(topLevel.body).parent_id).toBeNull();
    const nested = await call('patch', `/api/categories/${child.id}`, owner, {
      parent_id: parent.id,
    });
    expect(Category.parse(nested.body).parent_id).toBe(parent.id);
  });

  it('refuses bad names, bad nesting and unknown keys with contract codes', async () => {
    const list = CategoryList.parse((await call('get', '/api/categories')).body);
    const parent = list[0]!;
    const child = list[1]!;

    const taken = await call('post', '/api/categories', owner, {
      name: `C01 B Parent ${STAMP}`,
    });
    expect(taken.status).toBe(409);
    expect(code(taken)).toBe('CATEGORY_NAME_TAKEN');
    const blank = await call('post', '/api/categories', owner, { name: '   ' });
    expect(blank.status).toBe(400);
    expect(code(blank)).toBe('VALIDATION_FAILED');
    const tooLong = await call('post', '/api/categories', owner, { name: 'x'.repeat(61) });
    expect(code(tooLong)).toBe('VALIDATION_FAILED');
    const selfParent = await call('patch', `/api/categories/${parent.id}`, owner, {
      parent_id: parent.id,
    });
    expect(selfParent.status).toBe(400);
    expect(code(selfParent)).toBe('CATEGORY_DEPTH');
    const childAsParent = await call('patch', `/api/categories/${parent.id}`, owner, {
      parent_id: child.id,
    });
    expect(childAsParent.status).toBe(400);
    expect(code(childAsParent)).toBe('CATEGORY_DEPTH');
    const unknownKey = await call('patch', `/api/categories/${parent.id}`, owner, {
      sku: 'x',
    });
    expect(unknownKey.status).toBe(400);
    expect(code(unknownKey)).toBe('VALIDATION_FAILED');
    const nothing = await call('patch', `/api/categories/${parent.id}`, owner, {});
    expect(nothing.status).toBe(400);
    expect(code(nothing)).toBe('VALIDATION_FAILED');
    const missing = await call(
      'patch',
      `/api/categories/${'00000000-0000-0000-0000-000000000000'}`,
      owner,
      { name: 'Nope' },
    );
    expect(missing.status).toBe(404);
    expect(code(missing)).toBe('CATEGORY_NOT_FOUND');
    const foreignParent = await call('post', '/api/categories', owner, {
      name: 'Orphan',
      parent_id: '00000000-0000-0000-0000-000000000000',
    });
    expect(foreignParent.status).toBe(404);
    expect(code(foreignParent)).toBe('CATEGORY_NOT_FOUND');
  });

  it('archive: refused with children, moves active products with the move target', async () => {
    const list = CategoryList.parse((await call('get', '/api/categories')).body);
    const parent = list[0]!;
    const child = list[1]!;
    const other = list[2]!;

    // A product in "other" (the shop's standard tax class, seeded by T01).
    const standard = await service
      .from('tax_classes')
      .select('id')
      .eq('organization_id', org)
      .eq('kind', 'standard')
      .single();
    expect(standard.error).toBeNull();
    const product = await service.from('products').insert({
      organization_id: org,
      name_ar: 'C01 Product',
      sku: `C01-P${STAMP}`,
      cash_price: '100.00',
      tax_class_id: standard.data!.id,
      category_id: other.id,
    });
    expect(product.error, JSON.stringify(product.error)).toBeNull();

    // Active children block the archive (a move target does not change that).
    const inUse = await call('post', `/api/categories/${parent.id}/archive`, owner, {
      move_to_category_id: other.id,
    });
    expect(inUse.status).toBe(409);
    expect(code(inUse)).toBe('CATEGORY_IN_USE');
    expect(ErrorResponse.parse(inUse.body).error.details).toEqual({
      active_products: 0,
      active_children: 1,
    });

    // The move target archives "other" and moves the product in one transaction.
    const archived = await call('post', `/api/categories/${other.id}/archive`, owner, {
      move_to_category_id: parent.id,
    });
    expect(archived.status, JSON.stringify(archived.body)).toBe(200);
    expect(Category.parse(archived.body).archived_at).not.toBeNull();
    const moved = await service
      .from('products')
      .select('category_id')
      .eq('organization_id', org)
      .eq('sku', `C01-P${STAMP}`)
      .single();
    expect(moved.error).toBeNull();
    expect(moved.data!.category_id).toBe(parent.id);
    // The audit row of the archive shows the move.
    const row = await service
      .from('audit_log')
      .select('action, after')
      .eq('organization_id', org)
      .eq('action', 'category.archived')
      .eq('entity_id', other.id)
      .single();
    expect(row.error, JSON.stringify(row.error)).toBeNull();
    expect((row.data!.after as { moved_products: number }).moved_products).toBe(1);

    // A childless, productless category archives directly.
    const archivedChild = await call('post', `/api/categories/${child.id}/archive`);
    expect(archivedChild.status).toBe(200);
    expect(Category.parse(archivedChild.body).archived_at).not.toBeNull();
    // Archived categories come last.
    const after = CategoryList.parse((await call('get', '/api/categories')).body);
    expect(after.map((c) => c.id)).toEqual([parent.id, child.id, other.id]);
    expect(after[0]!.archived_at).toBeNull();
    expect(after[1]!.archived_at).not.toBeNull();
    expect(after[2]!.archived_at).not.toBeNull();

    // Restore brings it back.
    const restored = await call('post', `/api/categories/${child.id}/restore`);
    expect(restored.status).toBe(200);
    expect(Category.parse(restored.body).archived_at).toBeNull();
  });

  it('the cashier reads the list and is refused every write', async () => {
    const list = await call('get', '/api/categories', cashier);
    expect(list.status, JSON.stringify(list.body)).toBe(200);
    expect(CategoryList.parse(list.body).length).toBe(3);
    const writes: [string, string, object][] = [
      ['post', '/api/categories', { name: 'Cashier cat' }],
      ['patch', `/api/categories/${CategoryList.parse(list.body)[0]!.id}`, { name: 'x' }],
      ['post', `/api/categories/${CategoryList.parse(list.body)[0]!.id}/archive`, {}],
      ['post', `/api/categories/${CategoryList.parse(list.body)[0]!.id}/restore`, {}],
    ];
    for (const [method, path, body] of writes) {
      const r = await call(method as 'post' | 'patch', path, cashier, body);
      expect(r.status, `${method} ${path}`).toBe(403);
      expect(code(r)).toBe('PERMISSION_DENIED');
    }
  });
});
