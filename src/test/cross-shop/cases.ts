// src/test/cross-shop/cases.ts
//
// One or more cross-shop cases per non-public route (D19, F05). A new route without a case here
// fails `npm run check:cross-shop` and `npm test` (check.test.ts).
//
// Pattern: log in as a user of shop A, aim the request at shop B (x-org-id, a body id, a path
// id), expect 403/404, then prove shop B didn't change (no audit row from this call's IP, B's
// session still works, A's password unchanged...).

import { randomUUID } from 'node:crypto';
import { crossShopCase, SHOP_A, SHOP_B, type CrossShopHarness } from './harness';

const OWNER_A = 'owner.one@ecotech.test';
const OWNER_B = 'owner.two@ecotech.test';
const SEED_PASSWORD = 'LocalDev-Only-2026!';
crossShopCase({
  method: 'GET',
  path: '/api/subscription',
  name: 'subscription status is scoped to caller shop',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/subscription', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    h.expect(h.code(foreign.res)).toBe('SHOP_NOT_ALLOWED');
    const injected = await h.call('GET', '/api/subscription', {
      token: a.accessToken,
      query: 'orgId=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const own = await h.call('GET', '/api/subscription', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
    h.expect(own.res.body.plan_key).toBe('retail_pro');
  },
});
// Seed ids (supabase/seeds/02_dev_data.sql).
const SHOP_A_BR1 = 'd2000000-0000-0000-0000-000000000011';
const SHOP_A_BR2 = 'd2000000-0000-0000-0000-000000000012';
const SHOP_B_BR1 = 'd2000000-0000-0000-0000-000000000021';
const CASHIER_A = 'd3000000-0000-0000-0000-000000000012';
const CASHIER_B = 'd3000000-0000-0000-0000-000000000022';

crossShopCase({
  method: 'GET',
  path: '/api/categories',
  name: 'categories list refuses a foreign shop header',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/categories', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/categories',
  name: 'category create rejects foreign header and tenant body',
  async run(h) {
    const a = await h.login(OWNER_A);
    const body = { name: `Cross-shop ${Date.now()}` };
    const foreign = await h.call('POST', '/api/categories', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/categories', {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

// The seeded shops have no categories (unlike tax classes, no seed trigger
// exists), so each case that needs a shop B category creates one first.
async function shopBCategory(h: CrossShopHarness, tag: string) {
  const b = await h.login(OWNER_B);
  const created = await h.call('POST', '/api/categories', {
    token: b.accessToken,
    body: { name: `Cross-shop ${tag} ${Date.now()}` },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  return (created.res.body as { id: string }).id;
}

for (const method of ['PATCH', 'POST'] as const) {
  const suffix = method === 'PATCH' ? '' : '/archive';
  crossShopCase({
    method,
    path: `/api/categories/:id${suffix}`,
    name: `${method} category rejects another shop's id`,
    async run(h) {
      const id = await shopBCategory(h, method.toLowerCase());
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/categories/${id}${suffix}`, {
        token: a.accessToken,
        body: method === 'PATCH' ? { name: `Foreign ${Date.now()}` } : {},
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('CATEGORY_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    },
  });
}

crossShopCase({
  method: 'POST',
  path: '/api/categories/:id/restore',
  name: 'category restore rejects another shop id',
  async run(h) {
    const id = await shopBCategory(h, 'restore');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('POST', `/api/categories/${id}/restore`, { token: a.accessToken });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('CATEGORY_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

// C02 products: shop B's product is created the real way, then shop A aims at it.
async function shopBProduct(h: CrossShopHarness, tag: string) {
  const b = await h.login(OWNER_B);
  const created = await h.call('POST', '/api/products', {
    token: b.accessToken,
    body: { name_ar: `Cross-shop ${tag}`, sku: `XS-${tag}-${Date.now()}`, cash_price: '10.00' },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  const product = created.res.body as { id: string; barcode: string };
  return { ...product, token: b.accessToken };
}

crossShopCase({
  method: 'GET',
  path: '/api/products',
  name: 'products list refuses a foreign shop header and an org query key',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/products', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/products', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/products/lookup',
  name: "product lookup never finds another shop's barcode",
  async run(h) {
    const product = await shopBProduct(h, 'lookup');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/products/lookup', {
      token: a.accessToken,
      query: 'code=' + encodeURIComponent(product.barcode),
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('PRODUCT_NOT_FOUND');
    const header = await h.call('GET', '/api/products/lookup', {
      token: a.accessToken,
      orgId: SHOP_B,
      query: 'code=' + encodeURIComponent(product.barcode),
    });
    h.expect(header.res.status).toBe(403);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/products/:id',
  name: "product read rejects another shop's id",
  async run(h) {
    const product = await shopBProduct(h, 'get');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', `/api/products/${product.id}`, { token: a.accessToken });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('PRODUCT_NOT_FOUND');
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/products/:id/units',
  name: "product units (labels) reject another shop's product id",
  async run(h) {
    const product = await shopBProduct(h, 'units');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', `/api/products/${product.id}/units`, {
      token: a.accessToken,
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('PRODUCT_NOT_FOUND');
    const header = await h.call('GET', `/api/products/${product.id}/units`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/products',
  name: 'product create rejects foreign header and tenant body',
  async run(h) {
    const a = await h.login(OWNER_A);
    const body = { name_ar: 'Cross-shop', sku: `XS-NEW-${Date.now()}`, cash_price: '1.00' };
    const foreign = await h.call('POST', '/api/products', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/products', {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

for (const [method, suffix] of [
  ['PATCH', ''],
  ['POST', '/archive'],
] as const) {
  crossShopCase({
    method,
    path: `/api/products/:id${suffix}`,
    name: `${method} product${suffix} rejects another shop's id`,
    async run(h) {
      const product = await shopBProduct(h, method.toLowerCase());
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/products/${product.id}${suffix}`, {
        token: a.accessToken,
        body: method === 'PATCH' ? { cash_price: '1.00' } : {},
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('PRODUCT_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    },
  });
}

crossShopCase({
  method: 'POST',
  path: '/api/products/:id/restore',
  name: "product restore rejects another shop's id",
  async run(h) {
    const product = await shopBProduct(h, 'restore');
    const archived = await h.call('POST', `/api/products/${product.id}/archive`, {
      token: product.token,
    });
    h.expect(archived.res.status).toBe(200);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('POST', `/api/products/${product.id}/restore`, {
      token: a.accessToken,
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('PRODUCT_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});
// I01 stock view: a foreign x-org-id, another shop's branch or product, an org key in the query.
crossShopCase({
  method: 'GET',
  path: '/api/stock',
  name: "stock view refuses a foreign header, another shop's branch and an org query key",
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/stock', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const branch = await h.call('GET', '/api/stock', {
      token: a.accessToken,
      query: 'branch_id=' + SHOP_B_BR1,
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const injected = await h.call('GET', '/api/stock', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/stock/movements',
  name: "stock movements refuse another shop's product and branch",
  async run(h) {
    const product = await shopBProduct(h, 'movements');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/stock/movements', {
      token: a.accessToken,
      query: 'product_id=' + product.id,
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('PRODUCT_NOT_FOUND');
    const header = await h.call('GET', '/api/stock/movements', {
      token: a.accessToken,
      orgId: SHOP_B,
      query: 'product_id=' + product.id,
    });
    h.expect(header.res.status).toBe(403);
    // I05: the shop-wide history aimed at shop B's branch.
    const branch = await h.call('GET', '/api/stock/movements', {
      token: a.accessToken,
      query: 'branch_id=' + SHOP_B_BR1,
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/stock/movements/export',
  name: "the movement export refuses another shop's product, branch, header and org key",
  async run(h) {
    const product = await shopBProduct(h, 'export');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('POST', '/api/stock/movements/export', {
      token: a.accessToken,
      body: { product_id: product.id },
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('PRODUCT_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_A, foreign.ip)).toBe(0);
    const branch = await h.call('POST', '/api/stock/movements/export', {
      token: a.accessToken,
      body: { branch_id: SHOP_B_BR1 },
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const header = await h.call('POST', '/api/stock/movements/export', {
      token: a.accessToken,
      orgId: SHOP_B,
      body: {},
    });
    h.expect(header.res.status).toBe(403);
    h.expect(await h.auditRowsFrom(SHOP_B, header.ip)).toBe(0);
    const injected = await h.call('POST', '/api/stock/movements/export', {
      token: a.accessToken,
      body: { organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
  },
});
// I06 low stock: shop A aims at shop B's product and branch; the summary never shows shop B.
crossShopCase({
  method: 'GET',
  path: '/api/stock/low-summary',
  name: 'the low-stock summary refuses a foreign shop header and an org query key',
  async run(h) {
    const a = await h.login(OWNER_A);
    const own = await h.call('GET', '/api/stock/low-summary', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
    const branches = (own.res.body as { branches: { branch_id: string }[] }).branches;
    h.expect(branches.some((b) => b.branch_id === SHOP_B_BR1)).toBe(false);
    const header = await h.call('GET', '/api/stock/low-summary', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', '/api/stock/low-summary', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/stock/min-levels/:id',
  name: "min levels refuse another shop's product",
  async run(h) {
    const product = await shopBProduct(h, 'minread');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', `/api/stock/min-levels/${product.id}`, {
      token: a.accessToken,
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('PRODUCT_NOT_FOUND');
    const header = await h.call('GET', `/api/stock/min-levels/${product.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
  },
});
crossShopCase({
  method: 'PUT',
  path: '/api/stock/min-levels/:id',
  name: "setting a min level refuses another shop's product and branch",
  async run(h) {
    const product = await shopBProduct(h, 'minset');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('PUT', `/api/stock/min-levels/${product.id}`, {
      token: a.accessToken,
      body: { branch_id: SHOP_A_BR1, min_stock: 5 },
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('PRODUCT_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_A, foreign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    const own = await h.call('POST', '/api/products', {
      token: a.accessToken,
      body: { name_ar: 'Cross-shop min', sku: `XS-MIN-${Date.now()}`, cash_price: '10.00' },
    });
    h.expect(own.res.status).toBe(201);
    const branch = await h.call(
      'PUT',
      `/api/stock/min-levels/${(own.res.body as { id: string }).id}`,
      {
        token: a.accessToken,
        body: { branch_id: SHOP_B_BR1, min_stock: 5 },
      },
    );
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const injected = await h.call('PUT', `/api/stock/min-levels/${product.id}`, {
      token: a.accessToken,
      body: { branch_id: SHOP_A_BR1, min_stock: 5, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
  },
});
// I02 adjustments and counts: shop B's documents are made the real way, then shop A aims at them.
const key = (tag: string) => `xs-${tag}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
async function shopBAdjustment(h: CrossShopHarness) {
  const product = await shopBProduct(h, 'adjustment');
  const posted = await h.call('POST', '/api/stock/adjustments', {
    token: product.token,
    idempotencyKey: key('adj'),
    body: {
      branch_id: SHOP_B_BR1,
      reason: 'found',
      lines: [{ product_id: product.id, quantity: 1 }],
    },
  });
  h.expect(posted.res.status, JSON.stringify(posted.res.body)).toBe(201);
  return (posted.res.body as { id: string }).id;
}
/** An open count of shop B over a new, empty category (never overlaps another open count). */
async function shopBCount(h: CrossShopHarness) {
  const b = await h.login(OWNER_B);
  const category = await h.call('POST', '/api/categories', {
    token: b.accessToken,
    body: { name: key('count') },
  });
  h.expect(category.res.status, JSON.stringify(category.res.body)).toBe(201);
  const created = await h.call('POST', '/api/stock/counts', {
    token: b.accessToken,
    idempotencyKey: key('count'),
    body: { branch_id: SHOP_B_BR1, category_id: (category.res.body as { id: string }).id },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  return (created.res.body as { id: string }).id;
}

for (const path of ['/api/stock/adjustments', '/api/stock/counts']) {
  crossShopCase({
    method: 'GET',
    path,
    name: `${path} refuses a foreign header, another shop's branch and an org query key`,
    async run(h) {
      const a = await h.login(OWNER_A);
      const foreign = await h.call('GET', path, { token: a.accessToken, orgId: SHOP_B });
      h.expect(foreign.res.status).toBe(403);
      const branch = await h.call('GET', path, {
        token: a.accessToken,
        query: 'branch_id=' + SHOP_B_BR1,
      });
      h.expect(branch.res.status).toBe(404);
      h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
      const injected = await h.call('GET', path, {
        token: a.accessToken,
        query: 'organization_id=' + SHOP_B,
      });
      h.expect(injected.res.status).toBe(400);
    },
  });
}

crossShopCase({
  method: 'GET',
  path: '/api/stock/adjustments/:id',
  name: "adjustment read rejects another shop's id",
  async run(h) {
    const id = await shopBAdjustment(h);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', `/api/stock/adjustments/${id}`, { token: a.accessToken });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('STOCK_ADJUSTMENT_NOT_FOUND');
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/stock/adjustments',
  name: "adjustment refuses another shop's product, branch, header and an org body key",
  async run(h) {
    const product = await shopBProduct(h, 'adjust-post');
    const a = await h.login(OWNER_A);
    const body = {
      branch_id: SHOP_A_BR1,
      reason: 'found',
      lines: [{ product_id: product.id, quantity: 1 }],
    };
    const foreignProduct = await h.call('POST', '/api/stock/adjustments', {
      token: a.accessToken,
      idempotencyKey: key('a1'),
      body,
    });
    h.expect(foreignProduct.res.status).toBe(404);
    h.expect(h.code(foreignProduct.res)).toBe('PRODUCT_NOT_FOUND');
    const foreignBranch = await h.call('POST', '/api/stock/adjustments', {
      token: a.accessToken,
      idempotencyKey: key('a2'),
      body: { ...body, branch_id: SHOP_B_BR1 },
    });
    h.expect(foreignBranch.res.status).toBe(404);
    h.expect(h.code(foreignBranch.res)).toBe('BRANCH_NOT_FOUND');
    const header = await h.call('POST', '/api/stock/adjustments', {
      token: a.accessToken,
      orgId: SHOP_B,
      idempotencyKey: key('a3'),
      body: { ...body, branch_id: SHOP_B_BR1 },
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('POST', '/api/stock/adjustments', {
      token: a.accessToken,
      idempotencyKey: key('a4'),
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    for (const sent of [foreignProduct, foreignBranch, header, injected]) {
      h.expect(await h.auditRowsFrom(SHOP_B, sent.ip)).toBe(0);
    }
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/stock/counts',
  name: "count create refuses another shop's branch, header and an org body key",
  async run(h) {
    const a = await h.login(OWNER_A);
    const branch = await h.call('POST', '/api/stock/counts', {
      token: a.accessToken,
      idempotencyKey: key('c1'),
      body: { branch_id: SHOP_B_BR1 },
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const header = await h.call('POST', '/api/stock/counts', {
      token: a.accessToken,
      orgId: SHOP_B,
      idempotencyKey: key('c2'),
      body: { branch_id: SHOP_B_BR1 },
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('POST', '/api/stock/counts', {
      token: a.accessToken,
      idempotencyKey: key('c3'),
      body: { branch_id: SHOP_A_BR1, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, branch.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, header.ip)).toBe(0);
  },
});

for (const [method, suffix, body] of [
  ['GET', '', undefined],
  ['PUT', '/lines', 'lines'],
  ['POST', '/scan', { code: 'XS-SCAN' }],
  ['POST', '/post', {}],
  ['POST', '/cancel', undefined],
] as const) {
  crossShopCase({
    method,
    path: `/api/stock/counts/:id${suffix}`,
    name: `${method} count${suffix} rejects another shop's id and leaves it open`,
    async run(h) {
      const id = await shopBCount(h);
      const product = body === 'lines' ? await shopBProduct(h, 'count-line') : undefined;
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/stock/counts/${id}${suffix}`, {
        token: a.accessToken,
        idempotencyKey: key('cx'),
        ...(body === 'lines'
          ? { body: { lines: [{ product_id: product?.id, counted_qty: 1 }] } }
          : body
            ? { body }
            : {}),
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('STOCK_COUNT_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      const b = await h.login(OWNER_B);
      const still = await h.call('GET', `/api/stock/counts/${id}`, { token: b.accessToken });
      h.expect((still.res.body as { status: string }).status).toBe('open');
    },
  });
}
// I03 transfers: shop B makes a real draft (a product with stock in its seed branch, sent to a
// second branch of its own), then shop A aims at it.
/** A draft transfer of shop B, from its seed branch to its second branch (created once). */
async function shopBTransfer(h: CrossShopHarness) {
  const product = await shopBProduct(h, 'transfer');
  const found = await h.call('POST', '/api/stock/adjustments', {
    token: product.token,
    idempotencyKey: key('tr-found'),
    body: {
      branch_id: SHOP_B_BR1,
      reason: 'found',
      lines: [{ product_id: product.id, quantity: 2 }],
    },
  });
  h.expect(found.res.status, JSON.stringify(found.res.body)).toBe(201);
  const branches = await h.call('GET', '/api/branches', { token: product.token });
  let other = (branches.res.body as { id: string }[]).find((b) => b.id !== SHOP_B_BR1);
  if (!other) {
    const made = await h.call('POST', '/api/branches', {
      token: product.token,
      body: { name: 'Cross-shop second', code: 'XS2' },
    });
    h.expect(made.res.status, JSON.stringify(made.res.body)).toBe(201);
    other = made.res.body as { id: string };
  }
  const created = await h.call('POST', '/api/stock/transfers', {
    token: product.token,
    idempotencyKey: key('tr'),
    body: {
      from_branch_id: SHOP_B_BR1,
      to_branch_id: other.id,
      lines: [{ product_id: product.id, quantity: 1 }],
    },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  return { id: (created.res.body as { id: string }).id, product: product.id, token: product.token };
}

crossShopCase({
  method: 'GET',
  path: '/api/stock/transfers',
  name: "transfers list refuses a foreign header, another shop's branch and an org query key",
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/stock/transfers', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const branch = await h.call('GET', '/api/stock/transfers', {
      token: a.accessToken,
      query: 'branch_id=' + SHOP_B_BR1,
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const injected = await h.call('GET', '/api/stock/transfers', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/stock/transfers/destinations',
  name: "transfer destinations list only the caller's shop and refuse a foreign header",
  async run(h) {
    const a = await h.login(OWNER_A);
    const own = await h.call('GET', '/api/stock/transfers/destinations', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
    h.expect((own.res.body as { id: string }[]).some((b) => b.id === SHOP_B_BR1)).toBe(false);
    const foreign = await h.call('GET', '/api/stock/transfers/destinations', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/stock/transfers',
  name: "transfer create refuses another shop's branches and products, a foreign header and an org key",
  async run(h) {
    const product = await shopBProduct(h, 'tr-create');
    const a = await h.login(OWNER_A);
    const own = { from_branch_id: SHOP_A_BR1, to_branch_id: SHOP_A_BR2 };
    const toB = await h.call('POST', '/api/stock/transfers', {
      token: a.accessToken,
      idempotencyKey: key('t1'),
      body: {
        from_branch_id: SHOP_A_BR1,
        to_branch_id: SHOP_B_BR1,
        lines: [{ product_id: product.id, quantity: 1 }],
      },
    });
    h.expect(toB.res.status).toBe(404);
    h.expect(h.code(toB.res)).toBe('BRANCH_NOT_FOUND');
    const productB = await h.call('POST', '/api/stock/transfers', {
      token: a.accessToken,
      idempotencyKey: key('t2'),
      body: { ...own, lines: [{ product_id: product.id, quantity: 1 }] },
    });
    h.expect(productB.res.status).toBe(404);
    h.expect(h.code(productB.res)).toBe('PRODUCT_NOT_FOUND');
    const header = await h.call('POST', '/api/stock/transfers', {
      token: a.accessToken,
      orgId: SHOP_B,
      idempotencyKey: key('t3'),
      body: { ...own, lines: [{ product_id: product.id, quantity: 1 }] },
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('POST', '/api/stock/transfers', {
      token: a.accessToken,
      idempotencyKey: key('t4'),
      body: { ...own, organization_id: SHOP_B, lines: [{ product_id: product.id, quantity: 1 }] },
    });
    h.expect(injected.res.status).toBe(400);
    for (const sent of [toB, productB, header, injected]) {
      h.expect(await h.auditRowsFrom(SHOP_B, sent.ip)).toBe(0);
    }
  },
});

for (const [method, suffix, body] of [
  ['GET', '', undefined],
  ['PUT', '', 'lines'],
  ['POST', '/send', undefined],
  ['POST', '/receive', {}],
  ['POST', '/cancel', undefined],
] as const) {
  crossShopCase({
    method,
    path: `/api/stock/transfers/:id${suffix}`,
    name: `${method} transfer${suffix} rejects another shop's id and leaves it a draft`,
    async run(h) {
      const t = await shopBTransfer(h);
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/stock/transfers/${t.id}${suffix}`, {
        token: a.accessToken,
        ...(body === 'lines'
          ? { body: { lines: [{ product_id: t.product, quantity: 1 }] } }
          : body
            ? { body }
            : {}),
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('STOCK_TRANSFER_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      const still = await h.call('GET', `/api/stock/transfers/${t.id}`, { token: t.token });
      h.expect((still.res.body as { status: string }).status).toBe('draft');
    },
  });
}
// I04 units: shop B's plan has no serials, so shop A registers a unit the real way and shop B
// aims at it (and shop A aims at shop B's branch and product).
async function shopAUnit(h: CrossShopHarness) {
  const a = await h.login(OWNER_A);
  const product = await h.call('POST', '/api/products', {
    token: a.accessToken,
    body: {
      name_ar: 'Cross-shop phone',
      sku: key('XSU').toUpperCase(),
      cash_price: '10.00',
      is_serialized: true,
    },
  });
  h.expect(product.res.status, JSON.stringify(product.res.body)).toBe(201);
  const serial = key('XS')
    .toUpperCase()
    .replace(/[^A-Z0-9-]/g, '');
  const made = await h.call('POST', '/api/units', {
    token: a.accessToken,
    idempotencyKey: key('units'),
    body: {
      product_id: (product.res.body as { id: string }).id,
      branch_id: SHOP_A_BR1,
      cost: '5.00',
      serials: [serial],
    },
  });
  h.expect(made.res.status, JSON.stringify(made.res.body)).toBe(201);
  return { id: (made.res.body as { units: { id: string }[] }).units[0]!.id, serial };
}

crossShopCase({
  method: 'GET',
  path: '/api/units',
  name: "unit search refuses a foreign header, another shop's branch and an org query key",
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/units', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const branch = await h.call('GET', '/api/units', {
      token: a.accessToken,
      query: 'branch_id=' + SHOP_B_BR1,
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const injected = await h.call('GET', '/api/units', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
  },
});

for (const [path, by] of [
  ['/api/units/find', 'serial'],
  ['/api/units/:id', 'id'],
] as const) {
  crossShopCase({
    method: 'GET',
    path,
    name: `${path} never finds another shop's unit`,
    async run(h) {
      const unit = await shopAUnit(h);
      const b = await h.login(OWNER_B);
      const foreign = await h.call(
        'GET',
        by === 'id' ? `/api/units/${unit.id}` : '/api/units/find',
        { token: b.accessToken, ...(by === 'serial' ? { query: 'serial=' + unit.serial } : {}) },
      );
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('UNIT_NOT_FOUND');
    },
  });
}

crossShopCase({
  method: 'POST',
  path: '/api/units',
  name: "unit registration refuses another shop's branch and product, a foreign header and an org key",
  async run(h) {
    const productB = await shopBProduct(h, 'units');
    const a = await h.login(OWNER_A);
    const own = await h.call('POST', '/api/products', {
      token: a.accessToken,
      body: {
        name_ar: 'Cross-shop phone',
        sku: key('XSR').toUpperCase(),
        cash_price: '10.00',
        is_serialized: true,
      },
    });
    h.expect(own.res.status).toBe(201);
    const body = {
      product_id: (own.res.body as { id: string }).id,
      branch_id: SHOP_A_BR1,
      cost: '5.00',
      serials: [
        key('XR')
          .toUpperCase()
          .replace(/[^A-Z0-9-]/g, ''),
      ],
    };
    const toB = await h.call('POST', '/api/units', {
      token: a.accessToken,
      idempotencyKey: key('u1'),
      body: { ...body, branch_id: SHOP_B_BR1 },
    });
    h.expect(toB.res.status).toBe(404);
    h.expect(h.code(toB.res)).toBe('BRANCH_NOT_FOUND');
    const ofB = await h.call('POST', '/api/units', {
      token: a.accessToken,
      idempotencyKey: key('u2'),
      body: { ...body, product_id: productB.id },
    });
    h.expect(ofB.res.status).toBe(404);
    h.expect(h.code(ofB.res)).toBe('PRODUCT_NOT_FOUND');
    const header = await h.call('POST', '/api/units', {
      token: a.accessToken,
      orgId: SHOP_B,
      idempotencyKey: key('u3'),
      body,
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('POST', '/api/units', {
      token: a.accessToken,
      idempotencyKey: key('u4'),
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    for (const sent of [toB, ofB, header, injected]) {
      h.expect(await h.auditRowsFrom(SHOP_B, sent.ip)).toBe(0);
    }
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/auth/me',
  name: "shop A's owner can't read shop B's session data (x-org-id, query)",
  async run(h) {
    const a = await h.login(OWNER_A);

    const viaHeader = await h.call('GET', '/api/auth/me', { token: a.accessToken, orgId: SHOP_B });
    h.expect(viaHeader.res.status).toBe(403);
    h.expect(h.code(viaHeader.res)).toBe('SHOP_NOT_ALLOWED');

    const viaQuery = await h.call('GET', '/api/auth/me', {
      token: a.accessToken,
      query: `orgId=${SHOP_B}`,
    });
    h.expect(viaQuery.res.status).toBe(400);
    h.expect(h.code(viaQuery.res)).toBe('VALIDATION_FAILED');

    // Without a header the session stays in shop A.
    const own = await h.call('GET', '/api/auth/me', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
    h.expect((own.res.body as { org: { id: string } }).org.id).toBe(SHOP_A);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/auth/select-shop',
  name: "shop A's owner can't switch into shop B; nothing is written in B",
  async run(h) {
    const a = await h.login(OWNER_A);
    const { res, ip } = await h.call('POST', '/api/auth/select-shop', {
      token: a.accessToken,
      body: { orgId: SHOP_B },
    });
    h.expect(res.status).toBe(403);
    h.expect(h.code(res)).toBe('SHOP_NOT_ALLOWED');
    h.expect(await h.auditRowsFrom(SHOP_B, ip)).toBe(0);

    const orgInBody = await h.call('POST', '/api/auth/select-shop', {
      token: a.accessToken,
      body: { orgId: SHOP_A, organization_id: SHOP_B },
    });
    h.expect(orgInBody.res.status).toBe(400);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/auth/change-password',
  name: "shop A's owner aimed at shop B: refused, password unchanged, nothing written in B",
  async run(h) {
    const a = await h.login(OWNER_A);
    const { res, ip } = await h.call('POST', '/api/auth/change-password', {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { currentPassword: SEED_PASSWORD, newPassword: 'Cross-Shop-Never-2026!' },
    });
    h.expect(res.status).toBe(403);
    h.expect(h.code(res)).toBe('SHOP_NOT_ALLOWED');
    h.expect(await h.auditRowsFrom(SHOP_B, ip)).toBe(0);
    // The seed password still works, so nothing changed.
    await h.login(OWNER_A);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/auth/logout',
  name: "shop A's logout aimed at shop B ends only A's session and writes nothing in B",
  async run(h) {
    const b = await h.login(OWNER_B);
    const a = await h.login(OWNER_A);

    // logout skips the status gate on purpose and always ends the caller's own session (200).
    const { res, ip } = await h.call('POST', '/api/auth/logout', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(res.status).toBe(200);
    h.expect(await h.auditRowsFrom(SHOP_B, ip)).toBe(0);

    const bStill = await h.call('GET', '/api/auth/me', { token: b.accessToken });
    h.expect(bStill.res.status).toBe(200);
    h.expect((bStill.res.body as { org: { id: string } }).org.id).toBe(SHOP_B);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/me/permissions',
  name: "shop A's owner can't read shop B's permissions; own answer lists only shop A branches",
  async run(h) {
    const a = await h.login(OWNER_A);
    const aimed = await h.call('GET', '/api/me/permissions', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(aimed.res.status).toBe(403);
    h.expect(h.code(aimed.res)).toBe('SHOP_NOT_ALLOWED');

    const own = await h.call('GET', '/api/me/permissions', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
    const body = own.res.body as { keys: string[]; branchIds: string[]; allBranches: boolean };
    h.expect(body.allBranches).toBe(true);
    h.expect(body.branchIds.sort()).toEqual([SHOP_A_BR1, SHOP_A_BR2]);
    h.expect(body.branchIds).not.toContain(SHOP_B_BR1);
  },
});

crossShopCase({
  method: 'PUT',
  path: '/api/employees/:employeeId/permissions',
  name: "shop A's owner on shop B's employee: 404, nothing changed or written in B",
  async run(h) {
    const a = await h.login(OWNER_A);
    const before = await h.accessOf(CASHIER_B);
    const body = { permissionKey: 'sale.void', granted: true, reason: 'cross-shop test' };

    const byId = await h.call('PUT', `/api/employees/${CASHIER_B}/permissions`, {
      token: a.accessToken,
      body,
    });
    h.expect(byId.res.status).toBe(404);
    h.expect(h.code(byId.res)).toBe('NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, byId.ip)).toBe(0);

    const byHeader = await h.call('PUT', `/api/employees/${CASHIER_B}/permissions`, {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(byHeader.res.status).toBe(403);
    h.expect(h.code(byHeader.res)).toBe('SHOP_NOT_ALLOWED');
    h.expect(await h.auditRowsFrom(SHOP_B, byHeader.ip)).toBe(0);

    h.expect(await h.accessOf(CASHIER_B)).toEqual(before);
  },
});

crossShopCase({
  method: 'PUT',
  path: '/api/employees/:employeeId/branches',
  name: "shop A's owner: B's employee is 404, B's branch is refused; nothing changed",
  async run(h) {
    const a = await h.login(OWNER_A);
    const beforeB = await h.accessOf(CASHIER_B);
    const beforeA = await h.accessOf(CASHIER_A);

    const otherEmployee = await h.call('PUT', `/api/employees/${CASHIER_B}/branches`, {
      token: a.accessToken,
      body: { branchIds: [SHOP_A_BR1], reason: 'cross-shop test' },
    });
    h.expect(otherEmployee.res.status).toBe(404);
    h.expect(h.code(otherEmployee.res)).toBe('NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, otherEmployee.ip)).toBe(0);

    const otherBranch = await h.call('PUT', `/api/employees/${CASHIER_A}/branches`, {
      token: a.accessToken,
      body: { branchIds: [SHOP_A_BR1, SHOP_B_BR1], reason: 'cross-shop test' },
    });
    h.expect(otherBranch.res.status).toBe(422);
    h.expect(h.code(otherBranch.res)).toBe('BRANCH_NOT_IN_ORG');

    h.expect(await h.accessOf(CASHIER_B)).toEqual(beforeB);
    h.expect(await h.accessOf(CASHIER_A)).toEqual(beforeA);
  },
});

crossShopCase({
  method: 'PUT',
  path: '/api/employees/:employeeId/active',
  name: "shop A's owner: B's employee is 404 and stays active; aimed at B is refused; nothing written in B",
  async run(h) {
    const a = await h.login(OWNER_A);
    const beforeB = await h.accessOf(CASHIER_B);
    h.expect(beforeB.active).toBe(true);

    const otherEmployee = await h.call('PUT', `/api/employees/${CASHIER_B}/active`, {
      token: a.accessToken,
      body: { active: false, reason: 'cross-shop test' },
    });
    h.expect(otherEmployee.res.status).toBe(404);
    h.expect(h.code(otherEmployee.res)).toBe('NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, otherEmployee.ip)).toBe(0);

    const aimed = await h.call('PUT', `/api/employees/${CASHIER_B}/active`, {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { active: false, reason: 'cross-shop test' },
    });
    h.expect(aimed.res.status).toBe(403);
    h.expect(h.code(aimed.res)).toBe('SHOP_NOT_ALLOWED');

    h.expect(await h.accessOf(CASHIER_B)).toEqual(beforeB);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/audit',
  name: "shop A's owner never sees shop B's audit rows, can't aim at B or pass an org",
  async run(h) {
    const OWNER_B_EMPLOYEE = 'd3000000-0000-0000-0000-000000000021';
    await h.login(OWNER_B); // writes an auth.login row in shop B
    const a = await h.login(OWNER_A);

    const byActor = await h.call('GET', '/api/audit', {
      token: a.accessToken,
      query: `actorEmployeeId=${OWNER_B_EMPLOYEE}&action=auth.login`,
    });
    h.expect(byActor.res.status).toBe(200);
    h.expect((byActor.res.body as { total: number }).total).toBe(0);

    const page = await h.call('GET', '/api/audit', {
      token: a.accessToken,
      query: 'pageSize=100',
    });
    h.expect(page.res.status).toBe(200);
    const rows = (
      page.res.body as { items: { employeeId: string | null; branchId: string | null }[] }
    ).items;
    h.expect(rows.length).toBeGreaterThan(0); // A's own logins are there
    h.expect(rows.some((r) => r.employeeId === OWNER_B_EMPLOYEE)).toBe(false);
    h.expect(rows.some((r) => r.branchId === SHOP_B_BR1)).toBe(false);

    const aimed = await h.call('GET', '/api/audit', { token: a.accessToken, orgId: SHOP_B });
    h.expect(aimed.res.status).toBe(403);
    h.expect(h.code(aimed.res)).toBe('SHOP_NOT_ALLOWED');

    const orgInQuery = await h.call('GET', '/api/audit', {
      token: a.accessToken,
      query: `organization_id=${SHOP_B}`,
    });
    h.expect(orgInQuery.res.status).toBe(400);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/monitoring/test-error',
  name: "shop A's owner can't raise the monitoring test error in shop B; a cashier can't at all",
  async run(h) {
    const a = await h.login(OWNER_A);
    const aimed = await h.call('POST', '/api/monitoring/test-error', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(aimed.res.status).toBe(403);
    h.expect(h.code(aimed.res)).toBe('SHOP_NOT_ALLOWED');

    const cashier = await h.login('cashier.one@ecotech.test');
    const denied = await h.call('POST', '/api/monitoring/test-error', {
      token: cashier.accessToken,
    });
    h.expect(denied.res.status).toBe(403);
    h.expect(h.code(denied.res)).toBe('PERMISSION_DENIED');

    // The owner in their own shop gets the deliberate 500, with a request id to look up.
    const own = await h.call('POST', '/api/monitoring/test-error', { token: a.accessToken });
    h.expect(own.res.status).toBe(500);
    h.expect(h.code(own.res)).toBe('INTERNAL');
    h.expect((own.res.body as { error: { requestId?: string } }).error.requestId).toBeTruthy();
  },
});

// F14 files. A real file of shop B needs seeded data, so these cases use an id that is not in
// any shop: shop A must get the same answer it gets for a file that doesn't exist.
const NO_SUCH_FILE = '00000000-0000-4000-8000-00000000f14f';

crossShopCase({
  method: 'POST',
  path: '/api/files',
  name: "shop A's owner aimed at shop B: refused before any file is stored; nothing written in B",
  async run(h) {
    const a = await h.login(OWNER_A);
    const { res, ip } = await h.call('POST', '/api/files', { token: a.accessToken, orgId: SHOP_B });
    h.expect(res.status).toBe(403);
    h.expect(h.code(res)).toBe('SHOP_NOT_ALLOWED');
    h.expect(await h.auditRowsFrom(SHOP_B, ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/files/:id/url',
  name: "shop A's owner: another shop's file id reads as not found; aimed at B is refused",
  async run(h) {
    const a = await h.login(OWNER_A);
    const missing = await h.call('GET', `/api/files/${NO_SUCH_FILE}/url`, { token: a.accessToken });
    h.expect(missing.res.status).toBe(404);
    h.expect(h.code(missing.res)).toBe('FILE_NOT_FOUND');

    const aimed = await h.call('GET', `/api/files/${NO_SUCH_FILE}/url`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(aimed.res.status).toBe(403);
    h.expect(h.code(aimed.res)).toBe('SHOP_NOT_ALLOWED');
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/files',
  name: "shop A's owner: a record of shop B is not found; aimed at B is refused",
  async run(h) {
    const a = await h.login(OWNER_A);
    const other = await h.call('GET', `/api/files`, {
      token: a.accessToken,
      query: `entityType=customer&entityId=${NO_SUCH_FILE}`,
    });
    h.expect(other.res.status).toBe(404);
    h.expect(h.code(other.res)).toBe('NOT_FOUND');

    const aimed = await h.call('GET', '/api/files', {
      token: a.accessToken,
      orgId: SHOP_B,
      query: `entityType=customer&entityId=${NO_SUCH_FILE}`,
    });
    h.expect(aimed.res.status).toBe(403);
    h.expect(h.code(aimed.res)).toBe('SHOP_NOT_ALLOWED');
  },
});

// O01 branch reads and writes cannot target a foreign tenant.
for (const path of ['/api/branches', '/api/branches/manage'])
  crossShopCase({
    method: 'GET',
    path,
    name: path + ' rejects foreign shop header',
    async run(h) {
      const a = await h.login(OWNER_A);
      const foreign = await h.call('GET', path, { token: a.accessToken, orgId: SHOP_B });
      h.expect(foreign.res.status).toBe(403);
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      const own = await h.call('GET', path, { token: a.accessToken });
      h.expect(own.res.status).toBe(200);
      h.expect(own.res.body.every((b: { id: string }) => b.id !== SHOP_B_BR1)).toBe(true);
    },
  });
crossShopCase({
  method: 'POST',
  path: '/api/branches',
  name: 'branch create rejects foreign shop header and injected tenant',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('POST', '/api/branches', {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { name: 'Foreign', code: 'FORE' },
    });
    h.expect(foreign.res.status).toBe(403);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    const injected = await h.call('POST', '/api/branches', {
      token: a.accessToken,
      body: { name: 'Foreign', code: 'FORE', organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
  },
});
for (const [method, suffix, body] of [
  ['GET', '', undefined],
  ['PATCH', '', { name: 'Hijack' }],
  ['GET', '/deactivation-check', undefined],
  ['POST', '/deactivate', { reason: 'Hijack', confirm: true }],
  ['POST', '/reactivate', undefined],
] as const)
  crossShopCase({
    method,
    path: '/api/branches/:id' + suffix,
    name: method + ' branch ' + suffix + ' refuses foreign id',
    async run(h) {
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, '/api/branches/' + SHOP_B_BR1 + suffix, {
        token: a.accessToken,
        ...(body === undefined ? {} : { body }),
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('BRANCH_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    },
  });

for (const [method, suffix, body] of [
  ['PATCH', '', { full_name: 'Hijack' }],
  ['POST', '/invite', undefined],
  ['POST', '/password-reset', undefined],
] as const)
  crossShopCase({
    method,
    path: '/api/employees/:employeeId' + suffix,
    name: method + ' staff ' + suffix + ' refuses foreign id',
    async run(h) {
      const a = await h.login(OWNER_A);
      const f = await h.call(
        method,
        '/api/employees/d3000000-0000-0000-0000-000000000022' + suffix,
        { token: a.accessToken, ...(body ? { body } : {}) },
      );
      h.expect(f.res.status).toBe(404);
      h.expect(h.code(f.res)).toBe('EMPLOYEE_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, f.ip)).toBe(0);
    },
  });
for (const method of ['GET', 'POST'] as const)
  crossShopCase({
    method,
    path: '/api/employees',
    name: method + ' staff refuses foreign tenant header',
    async run(h) {
      const a = await h.login(OWNER_A);
      const f = await h.call(method, '/api/employees', {
        token: a.accessToken,
        orgId: SHOP_B,
        ...(method === 'POST'
          ? {
              body: {
                full_name: 'Hijack',
                email: 'hijack@example.com',
                role: 'CASHIER',
                branch_ids: [SHOP_B_BR1],
              },
            }
          : {}),
      });
      h.expect(f.res.status).toBe(403);
      h.expect(await h.auditRowsFrom(SHOP_B, f.ip)).toBe(0);
      if (method === 'GET') {
        const own = await h.call('GET', '/api/employees', { token: a.accessToken });
        h.expect(own.res.status).toBe(200);
        h.expect(
          own.res.body.items.some(
            (e: { id: string }) => e.id === 'd3000000-0000-0000-0000-000000000022',
          ),
        ).toBe(false);
      }
    },
  });

// P03 settings: reads and writes stay in the caller's shop; a header aimed at shop B is refused
// and an injected tenant id is a validation error.
for (const [method, path, body] of [
  ['GET', '/api/settings', undefined],
  ['PATCH', '/api/settings', { name: 'Hijack' }],
  ['GET', '/api/settings/profile', undefined],
  ['PATCH', '/api/settings/profile', { legal_name: 'Hijack' }],
  ['GET', '/api/settings/installment-policies', undefined],
  ['POST', '/api/settings/installment-policies', { grace_days: 7 }],
] as const)
  crossShopCase({
    method,
    path,
    name: `${method} ${path} refuses a foreign shop header and an injected tenant`,
    async run(h) {
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, path, {
        token: a.accessToken,
        orgId: SHOP_B,
        ...(body === undefined ? {} : { body }),
      });
      h.expect(foreign.res.status).toBe(403);
      h.expect(h.code(foreign.res)).toBe('SHOP_NOT_ALLOWED');
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      if (body !== undefined) {
        const injected = await h.call(method, path, {
          token: a.accessToken,
          body: { ...body, organization_id: SHOP_B },
        });
        h.expect(injected.res.status).toBe(400);
        h.expect(await h.auditRowsFrom(SHOP_B, injected.ip)).toBe(0);
      }
    },
  });

// T01 tax classes: a foreign header is refused; another shop's class id is "not found".
crossShopCase({
  method: 'GET',
  path: '/api/tax-classes',
  name: 'tax classes list is scoped to the caller shop',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/tax-classes', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const b = await h.login(OWNER_B);
    const own = await h.call('GET', '/api/tax-classes', { token: a.accessToken });
    const theirs = await h.call('GET', '/api/tax-classes', { token: b.accessToken });
    const ownIds = new Set((own.res.body as { id: string }[]).map((c) => c.id));
    h.expect((theirs.res.body as { id: string }[]).some((c) => ownIds.has(c.id))).toBe(false);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/tax-classes',
  name: 'tax class create refuses a foreign header and an injected tenant',
  async run(h) {
    const a = await h.login(OWNER_A);
    const body = {
      name: 'Foreign',
      kind: 'standard',
      rate: '5',
      eta_tax_type: 'T1',
      eta_subtype: 'V010',
    };
    const foreign = await h.call('POST', '/api/tax-classes', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    const injected = await h.call('POST', '/api/tax-classes', {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
  },
});
for (const [method, suffix, body] of [
  ['PATCH', '', { rate: '10' }],
  ['POST', '/archive', undefined],
  ['POST', '/restore', undefined],
] as const)
  crossShopCase({
    method,
    path: '/api/tax-classes/:id' + suffix,
    name: `${method} tax class ${suffix} refuses another shop's class`,
    async run(h) {
      const b = await h.login(OWNER_B);
      const theirs = await h.call('GET', '/api/tax-classes', { token: b.accessToken });
      const id = (theirs.res.body as { id: string }[])[0]!.id;
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/tax-classes/${id}${suffix}`, {
        token: a.accessToken,
        ...(body === undefined ? {} : { body }),
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('TAX_CLASS_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    },
  });

// U01 suppliers: shop B's supplier is created the real way, then shop A aims at it.
async function shopBSupplier(h: CrossShopHarness, tag: string) {
  const b = await h.login(OWNER_B);
  const created = await h.call('POST', '/api/suppliers', {
    token: b.accessToken,
    body: { name: `Cross-shop supplier ${tag} ${Date.now()}-${Math.random()}` },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  const supplier = created.res.body as { id: string; name: string; updated_at: string };
  return { ...supplier, token: b.accessToken };
}

crossShopCase({
  method: 'GET',
  path: '/api/suppliers',
  name: "suppliers list refuses a foreign header and an org query key, and never shows shop B's",
  async run(h) {
    const theirs = await shopBSupplier(h, 'list');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/suppliers', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/suppliers', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const own = await h.call('GET', '/api/suppliers', {
      token: a.accessToken,
      query: 'status=all&search=' + encodeURIComponent(theirs.name),
    });
    h.expect(own.res.status).toBe(200);
    h.expect((own.res.body as { total: number }).total).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

for (const suffix of ['', '/statement'] as const) {
  crossShopCase({
    method: 'GET',
    path: `/api/suppliers/:id${suffix}`,
    name: `supplier${suffix || ' read'} rejects another shop's id, a foreign header and an org query key`,
    async run(h) {
      const theirs = await shopBSupplier(h, 'get' + suffix);
      const a = await h.login(OWNER_A);
      const foreign = await h.call('GET', `/api/suppliers/${theirs.id}${suffix}`, {
        token: a.accessToken,
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('SUPPLIER_NOT_FOUND');
      const header = await h.call('GET', `/api/suppliers/${theirs.id}${suffix}`, {
        token: a.accessToken,
        orgId: SHOP_B,
      });
      h.expect(header.res.status).toBe(403);
      const injected = await h.call('GET', `/api/suppliers/${theirs.id}${suffix}`, {
        token: a.accessToken,
        query: 'organization_id=' + SHOP_B,
      });
      h.expect(injected.res.status).toBe(400);
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    },
  });
}

crossShopCase({
  method: 'POST',
  path: '/api/suppliers',
  name: 'supplier create rejects foreign header and tenant body',
  async run(h) {
    const a = await h.login(OWNER_A);
    const body = { name: `Cross-shop new supplier ${Date.now()}` };
    const foreign = await h.call('POST', '/api/suppliers', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/suppliers', {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, injected.ip)).toBe(0);
  },
});

for (const [method, suffix] of [
  ['PATCH', ''],
  ['POST', '/archive'],
] as const) {
  crossShopCase({
    method,
    path: `/api/suppliers/:id${suffix}`,
    name: `${method} supplier${suffix} rejects another shop's id and leaves it unchanged`,
    async run(h) {
      const theirs = await shopBSupplier(h, method.toLowerCase());
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/suppliers/${theirs.id}${suffix}`, {
        token: a.accessToken,
        body: method === 'PATCH' ? { notes: 'Foreign' } : {},
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('SUPPLIER_NOT_FOUND');
      const header = await h.call(method, `/api/suppliers/${theirs.id}${suffix}`, {
        token: a.accessToken,
        orgId: SHOP_B,
        body: method === 'PATCH' ? { notes: 'Foreign' } : {},
      });
      h.expect(header.res.status).toBe(403);
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_A, foreign.ip)).toBe(0);
      const after = await h.call('GET', `/api/suppliers/${theirs.id}`, { token: theirs.token });
      h.expect(after.res.body).toMatchObject({
        notes: null,
        archived_at: null,
        updated_at: theirs.updated_at,
      });
    },
  });
}

crossShopCase({
  method: 'POST',
  path: '/api/suppliers/:id/restore',
  name: "supplier restore rejects another shop's id",
  async run(h) {
    const theirs = await shopBSupplier(h, 'restore');
    const archived = await h.call('POST', `/api/suppliers/${theirs.id}/archive`, {
      token: theirs.token,
    });
    h.expect(archived.res.status).toBe(200);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('POST', `/api/suppliers/${theirs.id}/restore`, {
      token: a.accessToken,
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('SUPPLIER_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    const after = await h.call('GET', `/api/suppliers/${theirs.id}`, { token: theirs.token });
    h.expect((after.res.body as { archived_at: string | null }).archived_at).not.toBeNull();
  },
});

// R01 customers: shop B's customer (with a national ID) is created the real way, then shop A aims at it.
/** A valid national ID that is new on every call (random birth date and serial). */
function freshNationalId() {
  const two = (n: number) => String(n).padStart(2, '0');
  const pick = (from: number, to: number) => from + Math.floor(Math.random() * (to - from + 1));
  const serial = String(pick(0, 99999)).padStart(5, '0');
  return `2${two(pick(50, 99))}${two(pick(1, 12))}${two(pick(1, 28))}01${serial}`;
}

async function shopBCustomer(h: CrossShopHarness, tag: string) {
  const b = await h.login(OWNER_B);
  const national_id = freshNationalId();
  const created = await h.call('POST', '/api/customers', {
    token: b.accessToken,
    body: {
      full_name: `Cross-shop customer ${tag} ${Date.now()}-${Math.random()}`,
      phones: ['01000000099'],
      national_id,
    },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  const customer = created.res.body as { id: string; full_name: string; updated_at: string };
  return { ...customer, national_id, token: b.accessToken };
}

crossShopCase({
  method: 'GET',
  path: '/api/customers',
  name: "customers list refuses a foreign header and an org query key, and never shows shop B's, not even by national ID",
  async run(h) {
    const theirs = await shopBCustomer(h, 'list');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/customers', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/customers', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    for (const search of [theirs.full_name, theirs.national_id]) {
      const own = await h.call('GET', '/api/customers', {
        token: a.accessToken,
        query: 'search=' + encodeURIComponent(search),
      });
      h.expect(own.res.status).toBe(200);
      h.expect((own.res.body as { total: number }).total).toBe(0);
    }
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/customers/:id',
  name: "customer read rejects another shop's id, a foreign header and an org query key",
  async run(h) {
    const theirs = await shopBCustomer(h, 'get');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', `/api/customers/${theirs.id}`, { token: a.accessToken });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
    const header = await h.call('GET', `/api/customers/${theirs.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', `/api/customers/${theirs.id}`, {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/customers',
  name: "customer create rejects foreign header and tenant body; shop B's national ID is free in shop A",
  async run(h) {
    const theirs = await shopBCustomer(h, 'create');
    const a = await h.login(OWNER_A);
    const body = { full_name: `Cross-shop new customer ${Date.now()}`, phones: ['01000000098'] };
    const foreign = await h.call('POST', '/api/customers', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/customers', {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, injected.ip)).toBe(0);
    // The ID is unique per shop: the duplicate check must not see (or reveal) shop B's customer.
    const same = await h.call('POST', '/api/customers', {
      token: a.accessToken,
      body: { ...body, national_id: theirs.national_id },
    });
    h.expect(same.res.status, JSON.stringify(same.res.body)).toBe(201);
    h.expect((same.res.body as { id: string }).id).not.toBe(theirs.id);
  },
});

for (const [method, suffix] of [
  ['PATCH', ''],
  ['POST', '/status'],
] as const) {
  crossShopCase({
    method,
    path: `/api/customers/:id${suffix}`,
    name: `${method} customer${suffix} rejects another shop's id and leaves it unchanged`,
    async run(h) {
      const theirs = await shopBCustomer(h, method.toLowerCase());
      const a = await h.login(OWNER_A);
      const body =
        method === 'PATCH' ? { notes: 'Foreign' } : { status: 'blocked', reason: 'Foreign' };
      const foreign = await h.call(method, `/api/customers/${theirs.id}${suffix}`, {
        token: a.accessToken,
        body,
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
      const header = await h.call(method, `/api/customers/${theirs.id}${suffix}`, {
        token: a.accessToken,
        orgId: SHOP_B,
        body,
      });
      h.expect(header.res.status).toBe(403);
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_A, foreign.ip)).toBe(0);
      const after = await h.call('GET', `/api/customers/${theirs.id}`, { token: theirs.token });
      h.expect(after.res.body).toMatchObject({
        notes: null,
        status: 'active',
        national_id: theirs.national_id,
        updated_at: theirs.updated_at,
      });
    },
  });
}

// R04 guarantors: shop B's customer and guarantor (linked) are created the real way, then shop A aims at them.
async function shopBGuarantor(h: CrossShopHarness, tag: string) {
  const customer = await shopBCustomer(h, 'g-' + tag);
  const national_id = freshNationalId();
  const created = await h.call('POST', '/api/guarantors', {
    token: customer.token,
    body: {
      full_name: `Cross-shop guarantor ${tag} ${Date.now()}-${Math.random()}`,
      phone: '01000000097',
      national_id,
      link: { customer_id: customer.id, relation: 'friend' },
    },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  const guarantor = created.res.body as { id: string; full_name: string; updated_at: string };
  return { guarantor, customer, national_id, token: customer.token };
}

async function shopACustomer(h: CrossShopHarness, tag: string) {
  const a = await h.login(OWNER_A);
  const created = await h.call('POST', '/api/customers', {
    token: a.accessToken,
    body: { full_name: `Cross-shop A customer ${tag} ${Date.now()}`, phones: ['01000000096'] },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  return { id: (created.res.body as { id: string }).id, token: a.accessToken };
}

/**
 * The seed gives Dev Shop One (shop A) no installment policy; on a fresh database another suite may
 * or may not have published one yet. A case that needs one publishes it itself, so it never
 * depends on the order the test files run in.
 */
async function ensureShopAPolicy(h: CrossShopHarness) {
  const a = await h.login(OWNER_A);
  const current = await h.call('GET', '/api/settings', { token: a.accessToken });
  h.expect(current.res.status, JSON.stringify(current.res.body)).toBe(200);
  if ((current.res.body as { installment_policy: unknown }).installment_policy) return;
  const published = await h.call('POST', '/api/settings/installment-policies', {
    token: a.accessToken,
    body: { grace_days: 0 },
  });
  h.expect(published.res.status, JSON.stringify(published.res.body)).toBe(201);
}

async function shopAGuarantor(h: CrossShopHarness, tag: string) {
  const a = await h.login(OWNER_A);
  const created = await h.call('POST', '/api/guarantors', {
    token: a.accessToken,
    body: {
      full_name: `Cross-shop A guarantor ${tag} ${Date.now()}-${Math.random()}`,
      phone: '01000000095',
      national_id: freshNationalId(),
    },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  return { id: (created.res.body as { id: string }).id, token: a.accessToken };
}

crossShopCase({
  method: 'GET',
  path: '/api/guarantors',
  name: "guarantors list refuses a foreign header and an org query key, and never shows shop B's, not even by national ID",
  async run(h) {
    const theirs = await shopBGuarantor(h, 'list');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/guarantors', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/guarantors', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    for (const search of [theirs.guarantor.full_name, theirs.national_id]) {
      const own = await h.call('GET', '/api/guarantors', {
        token: a.accessToken,
        query: 'status=all&search=' + encodeURIComponent(search),
      });
      h.expect(own.res.status).toBe(200);
      h.expect((own.res.body as { total: number }).total).toBe(0);
    }
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/guarantors/:id',
  name: "guarantor read rejects another shop's id, a foreign header and an org query key",
  async run(h) {
    const theirs = await shopBGuarantor(h, 'get');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', `/api/guarantors/${theirs.guarantor.id}`, {
      token: a.accessToken,
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('GUARANTOR_NOT_FOUND');
    const header = await h.call('GET', `/api/guarantors/${theirs.guarantor.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', `/api/guarantors/${theirs.guarantor.id}`, {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/guarantors',
  name: "guarantor create rejects foreign header and tenant body; shop B's ID is free in shop A; shop B's customer can not be linked",
  async run(h) {
    const theirs = await shopBGuarantor(h, 'create');
    const a = await h.login(OWNER_A);
    const body = {
      full_name: `Cross-shop new guarantor ${Date.now()}`,
      phone: '01000000094',
      national_id: freshNationalId(),
    };
    const foreign = await h.call('POST', '/api/guarantors', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/guarantors', {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, injected.ip)).toBe(0);
    // A link to shop B's customer: not found, and the guarantor is not created either (one transaction).
    const linked = await h.call('POST', '/api/guarantors', {
      token: a.accessToken,
      body: { ...body, link: { customer_id: theirs.customer.id, relation: 'friend' } },
    });
    h.expect(linked.res.status).toBe(404);
    h.expect(h.code(linked.res)).toBe('CUSTOMER_NOT_FOUND');
    const none = await h.call('GET', '/api/guarantors', {
      token: a.accessToken,
      query: 'status=all&search=' + body.national_id,
    });
    h.expect((none.res.body as { total: number }).total).toBe(0);
    // The ID is unique per shop: the duplicate check must not see (or reveal) shop B's guarantor.
    const same = await h.call('POST', '/api/guarantors', {
      token: a.accessToken,
      body: { ...body, national_id: theirs.national_id },
    });
    h.expect(same.res.status, JSON.stringify(same.res.body)).toBe(201);
    h.expect((same.res.body as { id: string }).id).not.toBe(theirs.guarantor.id);
  },
});

for (const [method, suffix] of [
  ['PATCH', ''],
  ['POST', '/archive'],
  ['POST', '/restore'],
] as const) {
  crossShopCase({
    method,
    path: `/api/guarantors/:id${suffix}`,
    name: `${method} guarantor${suffix} rejects another shop's id and leaves it unchanged`,
    async run(h) {
      const theirs = await shopBGuarantor(h, method.toLowerCase() + suffix.replace('/', '-'));
      const a = await h.login(OWNER_A);
      const body = method === 'PATCH' ? { body: { job: 'Foreign' } } : {};
      const foreign = await h.call(method, `/api/guarantors/${theirs.guarantor.id}${suffix}`, {
        token: a.accessToken,
        ...body,
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('GUARANTOR_NOT_FOUND');
      const header = await h.call(method, `/api/guarantors/${theirs.guarantor.id}${suffix}`, {
        token: a.accessToken,
        orgId: SHOP_B,
        ...body,
      });
      h.expect(header.res.status).toBe(403);
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_A, foreign.ip)).toBe(0);
      const after = await h.call('GET', `/api/guarantors/${theirs.guarantor.id}`, {
        token: theirs.token,
      });
      h.expect(after.res.body).toMatchObject({
        job: null,
        archived_at: null,
        updated_at: theirs.guarantor.updated_at,
      });
    },
  });
}

crossShopCase({
  method: 'GET',
  path: '/api/customers/:id/guarantors',
  name: "a customer's guarantor list rejects another shop's customer, a foreign header and an org query key",
  async run(h) {
    const theirs = await shopBGuarantor(h, 'cust-list');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', `/api/customers/${theirs.customer.id}/guarantors`, {
      token: a.accessToken,
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
    const header = await h.call('GET', `/api/customers/${theirs.customer.id}/guarantors`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', `/api/customers/${theirs.customer.id}/guarantors`, {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/customers/:id/guarantors',
  name: "linking rejects shop B's customer and shop B's guarantor, a foreign header and a tenant body",
  async run(h) {
    const theirs = await shopBGuarantor(h, 'link');
    const mine = await shopACustomer(h, 'link');
    const mineG = await shopAGuarantor(h, 'link');
    const customerForeign = await h.call(
      'POST',
      `/api/customers/${theirs.customer.id}/guarantors`,
      {
        token: mine.token,
        body: { guarantor_id: mineG.id, relation: 'friend' },
      },
    );
    h.expect(customerForeign.res.status).toBe(404);
    h.expect(h.code(customerForeign.res)).toBe('CUSTOMER_NOT_FOUND');
    const guarantorForeign = await h.call('POST', `/api/customers/${mine.id}/guarantors`, {
      token: mine.token,
      body: { guarantor_id: theirs.guarantor.id, relation: 'friend' },
    });
    h.expect(guarantorForeign.res.status).toBe(404);
    h.expect(h.code(guarantorForeign.res)).toBe('GUARANTOR_NOT_FOUND');
    const header = await h.call('POST', `/api/customers/${mine.id}/guarantors`, {
      token: mine.token,
      orgId: SHOP_B,
      body: { guarantor_id: mineG.id, relation: 'friend' },
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('POST', `/api/customers/${mine.id}/guarantors`, {
      token: mine.token,
      body: { guarantor_id: mineG.id, relation: 'friend', organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, customerForeign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, customerForeign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, guarantorForeign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, guarantorForeign.ip)).toBe(0);
    const still = await h.call('GET', `/api/customers/${theirs.customer.id}/guarantors`, {
      token: theirs.token,
    });
    h.expect((still.res.body as unknown[]).length).toBe(1);
  },
});

for (const [method, suffix] of [
  ['PATCH', ''],
  ['POST', '/unlink'],
] as const) {
  crossShopCase({
    method,
    path: `/api/customers/:id/guarantors/:guarantorId${suffix}`,
    name: `${method} customer guarantor${suffix} rejects shop B's customer and guarantor and leaves the link unchanged`,
    async run(h) {
      const theirs = await shopBGuarantor(h, 'link-' + method.toLowerCase());
      const mine = await shopACustomer(h, 'link-' + method.toLowerCase());
      const mineG = await shopAGuarantor(h, 'link-' + method.toLowerCase());
      const body = method === 'PATCH' ? { body: { relation: 'other' } } : {};
      const customerForeign = await h.call(
        method,
        `/api/customers/${theirs.customer.id}/guarantors/${theirs.guarantor.id}${suffix}`,
        { token: mine.token, ...body },
      );
      h.expect(customerForeign.res.status).toBe(404);
      h.expect(h.code(customerForeign.res)).toBe('CUSTOMER_NOT_FOUND');
      const guarantorForeign = await h.call(
        method,
        `/api/customers/${mine.id}/guarantors/${theirs.guarantor.id}${suffix}`,
        { token: mine.token, ...body },
      );
      h.expect(guarantorForeign.res.status).toBe(404);
      h.expect(h.code(guarantorForeign.res)).toBe('GUARANTOR_NOT_FOUND');
      const header = await h.call(
        method,
        `/api/customers/${mine.id}/guarantors/${mineG.id}${suffix}`,
        { token: mine.token, orgId: SHOP_B, ...body },
      );
      h.expect(header.res.status).toBe(403);
      h.expect(await h.auditRowsFrom(SHOP_B, customerForeign.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_A, customerForeign.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, guarantorForeign.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_A, guarantorForeign.ip)).toBe(0);
      const still = await h.call('GET', `/api/customers/${theirs.customer.id}/guarantors`, {
        token: theirs.token,
      });
      h.expect(still.res.body).toMatchObject([{ relation: 'friend' }]);
    },
  });
}

crossShopCase({
  method: 'GET',
  path: '/api/customers/:id/guarantor-requirement',
  name: "the guarantor requirement rejects another shop's customer, a foreign header and an org query key",
  async run(h) {
    const theirs = await shopBGuarantor(h, 'req');
    const a = await h.login(OWNER_A);
    const url = `/api/customers/${theirs.customer.id}/guarantor-requirement`;
    const foreign = await h.call('GET', url, {
      token: a.accessToken,
      query: 'financed_amount=1000.00',
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
    const header = await h.call('GET', url, {
      token: a.accessToken,
      orgId: SHOP_B,
      query: 'financed_amount=1000.00',
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', url, {
      token: a.accessToken,
      query: 'financed_amount=1000.00&organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

// R03 credit: shop B's customer gets an exception request the real way, then shop A aims at both.
async function shopBCreditException(h: CrossShopHarness, tag: string) {
  const customer = await shopBCustomer(h, 'cr-' + tag);
  const created = await h.call('POST', `/api/customers/${customer.id}/credit-exceptions`, {
    token: customer.token,
    body: { financed_amount: '500.00', reason: `Cross-shop credit ${tag}` },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  return { customer, exception: created.res.body as { id: string }, token: customer.token };
}

crossShopCase({
  method: 'GET',
  path: '/api/customers/:id/credit',
  name: "the credit profile rejects another shop's customer, a foreign header and an org query key",
  async run(h) {
    const theirs = await shopBCustomer(h, 'cr-profile');
    const a = await h.login(OWNER_A);
    const url = `/api/customers/${theirs.id}/credit`;
    const foreign = await h.call('GET', url, { token: a.accessToken });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
    const header = await h.call('GET', url, { token: a.accessToken, orgId: SHOP_B });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', url, {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'PUT',
  path: '/api/customers/:id/credit-limit',
  name: "setting a limit rejects another shop's customer, a foreign header and a tenant body, and shop B's limit does not move",
  async run(h) {
    const theirs = await shopBCustomer(h, 'cr-limit');
    const a = await h.login(OWNER_A);
    const url = `/api/customers/${theirs.id}/credit-limit`;
    const body = { credit_limit: '50000.00', reason: 'Cross-shop attempt' };
    const foreign = await h.call('PUT', url, { token: a.accessToken, body });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
    const header = await h.call('PUT', url, { token: a.accessToken, orgId: SHOP_B, body });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('PUT', url, {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const mine = await h.call('GET', `/api/customers/${theirs.id}/credit`, { token: theirs.token });
    h.expect(mine.res.status).toBe(200);
    h.expect((mine.res.body as { credit_limit: string }).credit_limit).toBe('0.00');
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, injected.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/customers/:id/credit-check',
  name: "the credit check rejects another shop's customer, a foreign header and an org query key",
  async run(h) {
    const theirs = await shopBCustomer(h, 'cr-check');
    const a = await h.login(OWNER_A);
    const url = `/api/customers/${theirs.id}/credit-check`;
    const foreign = await h.call('GET', url, {
      token: a.accessToken,
      query: 'financed_amount=1000.00',
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
    const header = await h.call('GET', url, {
      token: a.accessToken,
      orgId: SHOP_B,
      query: 'financed_amount=1000.00',
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', url, {
      token: a.accessToken,
      query: 'financed_amount=1000.00&organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/customers/:id/credit-exceptions',
  name: "asking for an exception rejects another shop's customer, a foreign header and a tenant body",
  async run(h) {
    const theirs = await shopBCustomer(h, 'cr-request');
    const a = await h.login(OWNER_A);
    const url = `/api/customers/${theirs.id}/credit-exceptions`;
    const body = { financed_amount: '500.00', reason: 'Cross-shop attempt' };
    const foreign = await h.call('POST', url, { token: a.accessToken, body });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
    const header = await h.call('POST', url, { token: a.accessToken, orgId: SHOP_B, body });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('POST', url, {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, injected.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/credit-exceptions',
  name: "the exception list never shows shop B's requests, and refuses a foreign header and an org query key",
  async run(h) {
    const theirs = await shopBCreditException(h, 'list');
    const a = await h.login(OWNER_A);
    const own = await h.call('GET', '/api/credit-exceptions', {
      token: a.accessToken,
      query: 'status=all',
    });
    h.expect(own.res.status).toBe(200);
    const items = (own.res.body as { items: Array<{ id: string }> }).items;
    h.expect(items.some((i) => i.id === theirs.exception.id)).toBe(false);
    const foreign = await h.call('GET', '/api/credit-exceptions', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/credit-exceptions', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/credit-exceptions/:id',
  name: "an exception read rejects another shop's id, a foreign header and an org query key",
  async run(h) {
    const theirs = await shopBCreditException(h, 'get');
    const a = await h.login(OWNER_A);
    const url = `/api/credit-exceptions/${theirs.exception.id}`;
    const foreign = await h.call('GET', url, { token: a.accessToken });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('APPROVAL_NOT_FOUND');
    const header = await h.call('GET', url, { token: a.accessToken, orgId: SHOP_B });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', url, {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/credit-exceptions/:id/decide',
  name: "deciding rejects another shop's exception, a foreign header and a tenant body, and it stays pending",
  async run(h) {
    const theirs = await shopBCreditException(h, 'decide');
    const a = await h.login(OWNER_A);
    const url = `/api/credit-exceptions/${theirs.exception.id}/decide`;
    const foreign = await h.call('POST', url, { token: a.accessToken, body: { approve: true } });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('APPROVAL_NOT_FOUND');
    const header = await h.call('POST', url, {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { approve: true },
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('POST', url, {
      token: a.accessToken,
      body: { approve: true, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const still = await h.call('GET', `/api/credit-exceptions/${theirs.exception.id}`, {
      token: theirs.token,
    });
    h.expect((still.res.body as { status: string }).status).toBe('pending');
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, injected.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/credit-exceptions/:id/cancel',
  name: "cancelling rejects another shop's exception and a foreign header, and it stays pending",
  async run(h) {
    const theirs = await shopBCreditException(h, 'cancel');
    const a = await h.login(OWNER_A);
    const url = `/api/credit-exceptions/${theirs.exception.id}/cancel`;
    const foreign = await h.call('POST', url, { token: a.accessToken });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('APPROVAL_NOT_FOUND');
    const header = await h.call('POST', url, { token: a.accessToken, orgId: SHOP_B });
    h.expect(header.res.status).toBe(403);
    const still = await h.call('GET', `/api/credit-exceptions/${theirs.exception.id}`, {
      token: theirs.token,
    });
    h.expect((still.res.body as { status: string }).status).toBe('pending');
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

// R02 customer account: three reads of shop B's customer from shop A, a foreign header and a tenant key.
for (const [path, suffix, tag] of [
  ['/api/customers/:id/account', 'account', 'acct'],
  ['/api/customers/:id/statement', 'statement', 'stmt'],
] as const) {
  crossShopCase({
    method: 'GET',
    path,
    name: `the customer ${suffix} rejects another shop's customer, a foreign header and an org query key`,
    async run(h) {
      const theirs = await shopBCustomer(h, tag);
      const a = await h.login(OWNER_A);
      const url = `/api/customers/${theirs.id}/${suffix}`;
      const foreign = await h.call('GET', url, { token: a.accessToken });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
      const header = await h.call('GET', url, { token: a.accessToken, orgId: SHOP_B });
      h.expect(header.res.status).toBe(403);
      const injected = await h.call('GET', url, {
        token: a.accessToken,
        query: 'organization_id=' + SHOP_B,
      });
      h.expect(injected.res.status).toBe(400);
      const mine = await h.call('GET', url, { token: theirs.token });
      h.expect(mine.res.status, JSON.stringify(mine.res.body)).toBe(200);
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    },
  });
}

crossShopCase({
  method: 'GET',
  path: '/api/customers/:id/contracts/:contractId/schedule',
  name: "a contract schedule rejects another shop's customer and a foreign header",
  async run(h) {
    const theirs = await shopBCustomer(h, 'sched');
    const a = await h.login(OWNER_A);
    // No route writes contracts yet (N02): any id is enough, the customer is checked first.
    const url = `/api/customers/${theirs.id}/contracts/${randomUUID()}/schedule`;
    const foreign = await h.call('GET', url, { token: a.accessToken });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
    const header = await h.call('GET', url, { token: a.accessToken, orgId: SHOP_B });
    h.expect(header.res.status).toBe(403);
    const mine = await h.call('GET', url, { token: theirs.token });
    h.expect(mine.res.status).toBe(404);
    h.expect(h.code(mine.res)).toBe('CONTRACT_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});
// U02 purchase invoices: shop B's supplier, product and draft invoice are made the real way.
async function shopBPurchase(h: CrossShopHarness, tag: string) {
  const supplier = await shopBSupplier(h, 'pi-' + tag);
  const product = await shopBProduct(h, 'pi-' + tag);
  const created = await h.call('POST', '/api/purchase-invoices', {
    token: supplier.token,
    idempotencyKey: `xs-pi-${tag}-${Date.now()}-${Math.random()}`,
    body: {
      supplier_id: supplier.id,
      branch_id: SHOP_B_BR1,
      invoice_date: new Date().toISOString().slice(0, 10),
      lines: [{ product_id: product.id, quantity: 1, unit_cost: '10.00' }],
    },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  const invoice = created.res.body as { id: string; updated_at: string };
  return { invoice, supplier, product, token: supplier.token };
}
async function invoiceStatus(h: CrossShopHarness, token: string, id: string) {
  const own = await h.call('GET', `/api/purchase-invoices/${id}`, { token });
  return own.res.body as { status: string; updated_at: string };
}

crossShopCase({
  method: 'GET',
  path: '/api/purchase-invoices',
  name: "purchase invoices list refuses a foreign header, an org query key and shop B's supplier",
  async run(h) {
    const theirs = await shopBPurchase(h, 'list');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/purchase-invoices', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/purchase-invoices', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const bySupplier = await h.call('GET', '/api/purchase-invoices', {
      token: a.accessToken,
      query: 'supplier_id=' + theirs.supplier.id,
    });
    h.expect(bySupplier.res.status).toBe(404);
    h.expect(h.code(bySupplier.res)).toBe('SUPPLIER_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/purchase-invoices/:id',
  name: "purchase invoice read rejects another shop's id and a foreign header",
  async run(h) {
    const theirs = await shopBPurchase(h, 'get');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', `/api/purchase-invoices/${theirs.invoice.id}`, {
      token: a.accessToken,
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('PURCHASE_INVOICE_NOT_FOUND');
    const header = await h.call('GET', `/api/purchase-invoices/${theirs.invoice.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/purchase-invoices',
  name: "purchase invoice create rejects a foreign header, a tenant body and shop B's supplier, branch or product",
  async run(h) {
    const theirs = await shopBPurchase(h, 'create');
    const a = await h.login(OWNER_A);
    const own = await h.call('POST', '/api/suppliers', {
      token: a.accessToken,
      body: { name: `Cross-shop PI supplier ${Date.now()}-${Math.random()}` },
    });
    h.expect(own.res.status, JSON.stringify(own.res.body)).toBe(201);
    const ownProduct = await h.call('POST', '/api/products', {
      token: a.accessToken,
      body: { name_ar: 'Cross-shop PI', sku: `XS-PI-${Date.now()}`, cash_price: '1.00' },
    });
    h.expect(ownProduct.res.status, JSON.stringify(ownProduct.res.body)).toBe(201);
    const body = {
      supplier_id: (own.res.body as { id: string }).id,
      branch_id: SHOP_A_BR1,
      invoice_date: new Date().toISOString().slice(0, 10),
      lines: [
        { product_id: (ownProduct.res.body as { id: string }).id, quantity: 1, unit_cost: '1.00' },
      ],
    };
    const send = (b: object, orgId?: string) =>
      h.call('POST', '/api/purchase-invoices', {
        token: a.accessToken,
        idempotencyKey: `xs-pi-a-${Date.now()}-${Math.random()}`,
        body: b,
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(body, SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const injected = await send({ ...body, organization_id: SHOP_B });
    h.expect(injected.res.status).toBe(400);
    const supplier = await send({ ...body, supplier_id: theirs.supplier.id });
    h.expect(supplier.res.status).toBe(404);
    h.expect(h.code(supplier.res)).toBe('SUPPLIER_NOT_FOUND');
    const branch = await send({ ...body, branch_id: SHOP_B_BR1 });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const product = await send({
      ...body,
      lines: [{ product_id: theirs.product.id, quantity: 1, unit_cost: '1.00' }],
    });
    h.expect(product.res.status).toBe(404);
    h.expect(h.code(product.res)).toBe('PRODUCT_NOT_FOUND');
    for (const call of [foreign, injected, supplier, branch, product]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});

for (const [method, suffix] of [
  ['PUT', ''],
  ['POST', '/approve'],
  ['POST', '/reject'],
] as const) {
  crossShopCase({
    method,
    path: `/api/purchase-invoices/:id${suffix}`,
    name: `${method} purchase invoice${suffix} rejects another shop's id and leaves it unchanged`,
    async run(h) {
      const theirs = await shopBPurchase(h, method.toLowerCase() + suffix.replace('/', '-'));
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/purchase-invoices/${theirs.invoice.id}${suffix}`, {
        token: a.accessToken,
        body:
          suffix === ''
            ? { supplier_invoice_no: 'FOREIGN' }
            : suffix === '/reject'
              ? { reason: 'Not mine' }
              : {},
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('PURCHASE_INVOICE_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_A, foreign.ip)).toBe(0);
      const after = await invoiceStatus(h, theirs.token, theirs.invoice.id);
      h.expect(after).toMatchObject({ status: 'draft', updated_at: theirs.invoice.updated_at });
    },
  });
}

// U06: the approval list refuses a foreign header and an org key, and never shows shop B's invoices.
crossShopCase({
  method: 'GET',
  path: '/api/purchase-approvals',
  name: "purchase approvals refuse a foreign header and an org query key, and never show shop B's",
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/purchase-approvals', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/purchase-approvals', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const branch = await h.call('GET', '/api/purchase-approvals', {
      token: a.accessToken,
      query: 'branch_id=' + SHOP_B_BR1,
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    for (const status of ['pending', 'approved', 'rejected']) {
      const own = await h.call('GET', '/api/purchase-approvals', {
        token: a.accessToken,
        query: 'pageSize=100&status=' + status,
      });
      h.expect(own.res.status).toBe(200);
      const branches = (own.res.body as { items: { invoice: { branch_id: string } }[] }).items.map(
        (i) => i.invoice.branch_id,
      );
      h.expect(branches.every((b) => b !== SHOP_B_BR1)).toBe(true);
    }
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

// K01 vaults (D56). Shop B's accounts and transfers are made by B's owner inside each case.
const cashKey = () => `xs-k01-${Date.now()}-${Math.random()}`;
async function cashAccountOf(h: CrossShopHarness, owner: string, opening?: string) {
  const o = await h.login(owner);
  const made = await h.call('POST', '/api/cash-accounts', {
    token: o.accessToken,
    body: { name: `XS bank ${Date.now()}-${Math.random()}`, kind: 'bank', branch_id: null },
  });
  h.expect(made.res.status).toBe(201);
  const id = (made.res.body as { id: string }).id;
  if (opening) {
    const funded = await h.call('POST', `/api/cash-accounts/${id}/opening`, {
      token: o.accessToken,
      idempotencyKey: cashKey(),
      body: { amount: opening, note: 'Cross-shop case' },
    });
    h.expect(funded.res.status).toBe(200);
  }
  return id;
}
async function shopBCashTransfer(h: CrossShopHarness) {
  const b = await h.login(OWNER_B);
  const from = await cashAccountOf(h, OWNER_B, '50.00');
  const to = await cashAccountOf(h, OWNER_B);
  const made = await h.call('POST', '/api/cash-transfers', {
    token: b.accessToken,
    idempotencyKey: cashKey(),
    body: { from_account_id: from, to_account_id: to, amount: '5.00' },
  });
  h.expect(made.res.status).toBe(201);
  return (made.res.body as { id: string }).id;
}
crossShopCase({
  method: 'GET',
  path: '/api/cash-accounts',
  name: "cash accounts refuse a foreign header, an org key and B's branch, and never list B's",
  async run(h) {
    const b = await cashAccountOf(h, OWNER_B);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/cash-accounts', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/cash-accounts', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const branch = await h.call('GET', '/api/cash-accounts', {
      token: a.accessToken,
      query: 'branch_id=' + SHOP_B_BR1,
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const own = await h.call('GET', '/api/cash-accounts', {
      token: a.accessToken,
      query: 'status=all',
    });
    h.expect(own.res.status).toBe(200);
    h.expect((own.res.body as { id: string }[]).some((x) => x.id === b)).toBe(false);
  },
});
for (const [method, suffix] of [
  ['GET', ''],
  ['GET', '/movements'],
  ['POST', '/deactivate'],
  ['POST', '/reactivate'],
] as const) {
  crossShopCase({
    method,
    path: `/api/cash-accounts/:id${suffix}`,
    name: `${method} cash-accounts/:id${suffix} on shop B's account is not found, no B audit row`,
    async run(h) {
      const b = await cashAccountOf(h, OWNER_B);
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/cash-accounts/${b}${suffix}`, {
        token: a.accessToken,
        orgId: SHOP_B,
      });
      h.expect(foreign.res.status).toBe(403);
      const res = await h.call(method, `/api/cash-accounts/${b}${suffix}`, {
        token: a.accessToken,
      });
      h.expect(res.res.status).toBe(404);
      h.expect(h.code(res.res)).toBe('CASH_ACCOUNT_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
    },
  });
}
crossShopCase({
  method: 'POST',
  path: '/api/cash-accounts',
  name: "creating a cash account refuses a foreign header, an org id and B's branch",
  async run(h) {
    const a = await h.login(OWNER_A);
    const body = { name: `XS safe ${Date.now()}`, kind: 'safe', branch_id: SHOP_B_BR1 };
    const foreign = await h.call('POST', '/api/cash-accounts', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/cash-accounts', {
      token: a.accessToken,
      body: { ...body, branch_id: SHOP_A_BR1, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const branch = await h.call('POST', '/api/cash-accounts', { token: a.accessToken, body });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, branch.ip)).toBe(0);
  },
});
crossShopCase({
  method: 'PATCH',
  path: '/api/cash-accounts/:id',
  name: "renaming shop B's cash account is not found; an org id is refused",
  async run(h) {
    const b = await cashAccountOf(h, OWNER_B);
    const a = await h.login(OWNER_A);
    const injected = await h.call('PATCH', `/api/cash-accounts/${b}`, {
      token: a.accessToken,
      body: { name: 'XS', organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const res = await h.call('PATCH', `/api/cash-accounts/${b}`, {
      token: a.accessToken,
      body: { name: 'XS renamed' },
    });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('CASH_ACCOUNT_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/cash-accounts/:id/opening',
  name: "an opening balance on shop B's account is not found and posts nothing",
  async run(h) {
    const b = await cashAccountOf(h, OWNER_B);
    const a = await h.login(OWNER_A);
    const res = await h.call('POST', `/api/cash-accounts/${b}/opening`, {
      token: a.accessToken,
      idempotencyKey: cashKey(),
      body: { amount: '10.00', note: 'Cross-shop case' },
    });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('CASH_ACCOUNT_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
    const own = await h.call('GET', `/api/cash-accounts/${b}`, {
      token: (await h.login(OWNER_B)).accessToken,
    });
    h.expect((own.res.body as { balance: string }).balance).toBe('0.00');
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/cash-transfers',
  name: "cash transfers refuse a foreign header, an org key and B's account, and never list B's",
  async run(h) {
    const t = await shopBCashTransfer(h);
    const b = await cashAccountOf(h, OWNER_B);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/cash-transfers', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/cash-transfers', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const account = await h.call('GET', '/api/cash-transfers', {
      token: a.accessToken,
      query: 'account_id=' + b,
    });
    h.expect(account.res.status).toBe(404);
    h.expect(h.code(account.res)).toBe('CASH_ACCOUNT_NOT_FOUND');
    const own = await h.call('GET', '/api/cash-transfers', {
      token: a.accessToken,
      query: 'pageSize=100',
    });
    h.expect(own.res.status).toBe(200);
    h.expect((own.res.body as { items: { id: string }[] }).items.some((x) => x.id === t)).toBe(
      false,
    );
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/cash-transfers/:id',
  name: "shop B's cash transfer is not found",
  async run(h) {
    const t = await shopBCashTransfer(h);
    const a = await h.login(OWNER_A);
    const res = await h.call('GET', `/api/cash-transfers/${t}`, { token: a.accessToken });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('CASH_TRANSFER_NOT_FOUND');
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/cash-transfers',
  name: "a transfer with shop B's account on either side is not found and moves no money",
  async run(h) {
    const b = await cashAccountOf(h, OWNER_B, '20.00');
    const mine = await cashAccountOf(h, OWNER_A, '20.00');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('POST', '/api/cash-transfers', {
      token: a.accessToken,
      orgId: SHOP_B,
      idempotencyKey: cashKey(),
      body: { from_account_id: mine, to_account_id: b, amount: '1.00' },
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/cash-transfers', {
      token: a.accessToken,
      idempotencyKey: cashKey(),
      body: { from_account_id: mine, to_account_id: b, amount: '1.00', organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    for (const body of [
      { from_account_id: mine, to_account_id: b, amount: '1.00' },
      { from_account_id: b, to_account_id: mine, amount: '1.00' },
    ]) {
      const res = await h.call('POST', '/api/cash-transfers', {
        token: a.accessToken,
        idempotencyKey: cashKey(),
        body,
      });
      h.expect(res.res.status).toBe(404);
      h.expect(h.code(res.res)).toBe('CASH_ACCOUNT_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
    }
    const bAfter = await h.call('GET', `/api/cash-accounts/${b}`, {
      token: (await h.login(OWNER_B)).accessToken,
    });
    h.expect((bAfter.res.body as { balance: string }).balance).toBe('20.00');
    const mineAfter = await h.call('GET', `/api/cash-accounts/${mine}`, { token: a.accessToken });
    h.expect((mineAfter.res.body as { balance: string }).balance).toBe('20.00');
  },
});

// U04 purchase returns (D57). Shop B's approved invoice, return and bank are made by B's owner.
async function approvedPurchase(h: CrossShopHarness, owner: string, branchId: string) {
  const o = await h.login(owner);
  const tag = `${Date.now()}-${Math.random()}`;
  const supplier = await h.call('POST', '/api/suppliers', {
    token: o.accessToken,
    body: { name: `XS return supplier ${tag}` },
  });
  h.expect(supplier.res.status, JSON.stringify(supplier.res.body)).toBe(201);
  const product = await h.call('POST', '/api/products', {
    token: o.accessToken,
    body: { name_ar: 'Cross-shop return', sku: `XS-PR-${tag}`.slice(0, 40), cash_price: '1.00' },
  });
  h.expect(product.res.status, JSON.stringify(product.res.body)).toBe(201);
  const created = await h.call('POST', '/api/purchase-invoices', {
    token: o.accessToken,
    idempotencyKey: `xs-pr-pi-${tag}`,
    body: {
      supplier_id: (supplier.res.body as { id: string }).id,
      branch_id: branchId,
      invoice_date: new Date().toISOString().slice(0, 10),
      lines: [
        { product_id: (product.res.body as { id: string }).id, quantity: 3, unit_cost: '10.00' },
      ],
    },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  const id = (created.res.body as { id: string }).id;
  const approved = await h.call('POST', `/api/purchase-invoices/${id}/approve`, {
    token: o.accessToken,
    body: {},
  });
  h.expect(approved.res.status, JSON.stringify(approved.res.body)).toBe(200);
  const invoice = approved.res.body as { id: string; supplier_id: string; lines: { id: string }[] };
  return {
    id,
    supplierId: invoice.supplier_id,
    lineId: invoice.lines[0]!.id,
    token: o.accessToken,
  };
}
const returnBody = (invoiceId: string, lineId: string, extra: object = {}) => ({
  purchase_invoice_id: invoiceId,
  refund_mode: 'supplier_credit',
  reason: 'Cross-shop case',
  lines: [{ invoice_line_id: lineId, quantity: 1 }],
  ...extra,
});
async function shopBReturn(h: CrossShopHarness) {
  const invoice = await approvedPurchase(h, OWNER_B, SHOP_B_BR1);
  const made = await h.call('POST', '/api/purchase-returns', {
    token: invoice.token,
    idempotencyKey: `xs-pr-${Date.now()}-${Math.random()}`,
    body: returnBody(invoice.id, invoice.lineId),
  });
  h.expect(made.res.status, JSON.stringify(made.res.body)).toBe(201);
  return { id: (made.res.body as { id: string }).id, invoice };
}
async function returnableOf(h: CrossShopHarness, token: string, invoiceId: string) {
  const own = await h.call('GET', `/api/purchase-invoices/${invoiceId}/returnable`, { token });
  return (own.res.body as { lines: { returnable: number }[] }).lines[0]!.returnable;
}
crossShopCase({
  method: 'GET',
  path: '/api/purchase-returns',
  name: "purchase returns list refuses a foreign header, an org key and shop B's supplier, invoice or branch",
  async run(h) {
    const theirs = await shopBReturn(h);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/purchase-returns', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/purchase-returns', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    for (const [query, code] of [
      ['supplier_id=' + theirs.invoice.supplierId, 'SUPPLIER_NOT_FOUND'],
      ['purchase_invoice_id=' + theirs.invoice.id, 'PURCHASE_INVOICE_NOT_FOUND'],
      ['branch_id=' + SHOP_B_BR1, 'BRANCH_NOT_FOUND'],
    ] as const) {
      const res = await h.call('GET', '/api/purchase-returns', { token: a.accessToken, query });
      h.expect(res.res.status).toBe(404);
      h.expect(h.code(res.res)).toBe(code);
    }
    const own = await h.call('GET', '/api/purchase-returns', {
      token: a.accessToken,
      query: 'pageSize=100',
    });
    h.expect(own.res.status).toBe(200);
    h.expect(
      (own.res.body as { items: { id: string }[] }).items.some((x) => x.id === theirs.id),
    ).toBe(false);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/purchase-returns/:id',
  name: "shop B's purchase return is not found; a foreign header is refused",
  async run(h) {
    const theirs = await shopBReturn(h);
    const a = await h.login(OWNER_A);
    const res = await h.call('GET', `/api/purchase-returns/${theirs.id}`, { token: a.accessToken });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('PURCHASE_RETURN_NOT_FOUND');
    const header = await h.call('GET', `/api/purchase-returns/${theirs.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/purchase-returns',
  name: "a return on shop B's invoice, line or cash account is refused and posts nothing",
  async run(h) {
    const theirs = await approvedPurchase(h, OWNER_B, SHOP_B_BR1);
    const theirBank = await cashAccountOf(h, OWNER_B);
    const mine = await approvedPurchase(h, OWNER_A, SHOP_A_BR1);
    const a = await h.login(OWNER_A);
    const send = (body: object, orgId?: string) =>
      h.call('POST', '/api/purchase-returns', {
        token: a.accessToken,
        idempotencyKey: `xs-pr-a-${Date.now()}-${Math.random()}`,
        body,
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(returnBody(mine.id, mine.lineId), SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const injected = await send(returnBody(mine.id, mine.lineId, { organization_id: SHOP_B }));
    h.expect(injected.res.status).toBe(400);
    const invoice = await send(returnBody(theirs.id, theirs.lineId));
    h.expect(invoice.res.status).toBe(404);
    h.expect(h.code(invoice.res)).toBe('PURCHASE_INVOICE_NOT_FOUND');
    const line = await send(returnBody(mine.id, theirs.lineId));
    h.expect(line.res.status).toBe(400);
    h.expect(h.code(line.res)).toBe('VALIDATION_FAILED');
    const account = await send(
      returnBody(mine.id, mine.lineId, { refund_mode: 'cash', cash_account_id: theirBank }),
    );
    h.expect(account.res.status).toBe(400);
    h.expect(h.code(account.res)).toBe('VAULT_INVALID');
    for (const call of [foreign, injected, invoice, line, account]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    h.expect(await returnableOf(h, theirs.token, theirs.id)).toBe(3);
    h.expect(await returnableOf(h, a.accessToken, mine.id)).toBe(3);
    const bank = await h.call('GET', `/api/cash-accounts/${theirBank}`, { token: theirs.token });
    h.expect((bank.res.body as { balance: string }).balance).toBe('0.00');
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/purchase-invoices/:id/returnable',
  name: "the returnable lines of shop B's invoice are not found; a foreign header is refused",
  async run(h) {
    const theirs = await approvedPurchase(h, OWNER_B, SHOP_B_BR1);
    const a = await h.login(OWNER_A);
    const res = await h.call('GET', `/api/purchase-invoices/${theirs.id}/returnable`, {
      token: a.accessToken,
    });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('PURCHASE_INVOICE_NOT_FOUND');
    const header = await h.call('GET', `/api/purchase-invoices/${theirs.id}/returnable`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/purchasing/cash-accounts',
  name: "payable cash accounts refuse a foreign header, an org key and B's branch, and never list B's",
  async run(h) {
    const theirBank = await cashAccountOf(h, OWNER_B);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/purchasing/cash-accounts', {
      token: a.accessToken,
      orgId: SHOP_B,
      query: 'branch_id=' + SHOP_A_BR1,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/purchasing/cash-accounts', {
      token: a.accessToken,
      query: `branch_id=${SHOP_A_BR1}&organization_id=${SHOP_B}`,
    });
    h.expect(injected.res.status).toBe(400);
    const branch = await h.call('GET', '/api/purchasing/cash-accounts', {
      token: a.accessToken,
      query: 'branch_id=' + SHOP_B_BR1,
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const own = await h.call('GET', '/api/purchasing/cash-accounts', {
      token: a.accessToken,
      query: 'branch_id=' + SHOP_A_BR1,
    });
    h.expect(own.res.status).toBe(200);
    h.expect(
      (own.res.body as { items: { id: string }[] }).items.some((x) => x.id === theirBank),
    ).toBe(false);
  },
});

// U03 supplier payments (D58). Shop B's payment is made by B's owner from a funded bank.
const payKey = () => `xs-u03-${Date.now()}-${Math.random()}`;
async function shopBPayment(h: CrossShopHarness) {
  const invoice = await approvedPurchase(h, OWNER_B, SHOP_B_BR1);
  const bank = await cashAccountOf(h, OWNER_B, '50.00');
  const made = await h.call('POST', '/api/supplier-payments', {
    token: invoice.token,
    idempotencyKey: payKey(),
    body: {
      supplier_id: invoice.supplierId,
      branch_id: SHOP_B_BR1,
      cash_account_id: bank,
      amount: '5.00',
    },
  });
  h.expect(made.res.status, JSON.stringify(made.res.body)).toBe(201);
  return { id: (made.res.body as { id: string }).id, invoice, bank };
}
crossShopCase({
  method: 'GET',
  path: '/api/supplier-payments',
  name: "supplier payments list refuses a foreign header, an org key and shop B's supplier or branch",
  async run(h) {
    const theirs = await shopBPayment(h);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/supplier-payments', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/supplier-payments', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    for (const [query, code] of [
      ['supplier_id=' + theirs.invoice.supplierId, 'SUPPLIER_NOT_FOUND'],
      ['branch_id=' + SHOP_B_BR1, 'BRANCH_NOT_FOUND'],
    ] as const) {
      const res = await h.call('GET', '/api/supplier-payments', { token: a.accessToken, query });
      h.expect(res.res.status).toBe(404);
      h.expect(h.code(res.res)).toBe(code);
    }
    const own = await h.call('GET', '/api/supplier-payments', {
      token: a.accessToken,
      query: 'pageSize=100',
    });
    h.expect(own.res.status).toBe(200);
    h.expect(
      (own.res.body as { items: { id: string }[] }).items.some((x) => x.id === theirs.id),
    ).toBe(false);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/supplier-payments/open-invoices',
  name: "the open invoices of shop B's supplier are not found; a foreign header and an org key are refused",
  async run(h) {
    const theirs = await approvedPurchase(h, OWNER_B, SHOP_B_BR1);
    const a = await h.login(OWNER_A);
    const query = 'supplier_id=' + theirs.supplierId;
    const res = await h.call('GET', '/api/supplier-payments/open-invoices', {
      token: a.accessToken,
      query,
    });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('SUPPLIER_NOT_FOUND');
    const header = await h.call('GET', '/api/supplier-payments/open-invoices', {
      token: a.accessToken,
      orgId: SHOP_B,
      query,
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', '/api/supplier-payments/open-invoices', {
      token: a.accessToken,
      query: query + '&organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/supplier-payments/:id',
  name: "shop B's supplier payment is not found; a foreign header is refused",
  async run(h) {
    const theirs = await shopBPayment(h);
    const a = await h.login(OWNER_A);
    const res = await h.call('GET', `/api/supplier-payments/${theirs.id}`, {
      token: a.accessToken,
    });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('SUPPLIER_PAYMENT_NOT_FOUND');
    const header = await h.call('GET', `/api/supplier-payments/${theirs.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/supplier-payments',
  name: "a payment with shop B's supplier, invoice, branch or cash account is refused and moves no money",
  async run(h) {
    const theirs = await approvedPurchase(h, OWNER_B, SHOP_B_BR1);
    const theirBank = await cashAccountOf(h, OWNER_B, '20.00');
    const mine = await approvedPurchase(h, OWNER_A, SHOP_A_BR1);
    const myBank = await cashAccountOf(h, OWNER_A, '20.00');
    const a = await h.login(OWNER_A);
    const body = {
      supplier_id: mine.supplierId,
      branch_id: SHOP_A_BR1,
      cash_account_id: myBank,
      amount: '1.00',
    };
    const send = (b: object, orgId?: string) =>
      h.call('POST', '/api/supplier-payments', {
        token: a.accessToken,
        idempotencyKey: payKey(),
        body: b,
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(body, SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const injected = await send({ ...body, organization_id: SHOP_B });
    h.expect(injected.res.status).toBe(400);
    const supplier = await send({ ...body, supplier_id: theirs.supplierId });
    h.expect(supplier.res.status).toBe(404);
    h.expect(h.code(supplier.res)).toBe('SUPPLIER_NOT_FOUND');
    const branch = await send({ ...body, branch_id: SHOP_B_BR1 });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const account = await send({ ...body, cash_account_id: theirBank });
    h.expect(account.res.status).toBe(400);
    h.expect(h.code(account.res)).toBe('VAULT_INVALID');
    const invoice = await send({
      ...body,
      allocations: [{ purchase_invoice_id: theirs.id, amount: '1.00' }],
    });
    h.expect(invoice.res.status).toBe(400);
    h.expect(h.code(invoice.res)).toBe('ALLOCATION_INVALID');
    for (const call of [foreign, injected, supplier, branch, account, invoice]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    const mineAfter = await h.call('GET', `/api/cash-accounts/${myBank}`, { token: a.accessToken });
    h.expect((mineAfter.res.body as { balance: string }).balance).toBe('20.00');
    const theirsAfter = await h.call('GET', `/api/cash-accounts/${theirBank}`, {
      token: theirs.token,
    });
    h.expect((theirsAfter.res.body as { balance: string }).balance).toBe('20.00');
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/supplier-payments/:id/reverse',
  name: "reversing shop B's supplier payment is not found and leaves it as it was",
  async run(h) {
    const theirs = await shopBPayment(h);
    const a = await h.login(OWNER_A);
    const send = (orgId?: string) =>
      h.call('POST', `/api/supplier-payments/${theirs.id}/reverse`, {
        token: a.accessToken,
        idempotencyKey: payKey(),
        body: { reason: 'Cross-shop case' },
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const res = await send();
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('SUPPLIER_PAYMENT_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
    const own = await h.call('GET', `/api/supplier-payments/${theirs.id}`, {
      token: theirs.invoice.token,
    });
    h.expect(
      (own.res.body as { reversed_by_payment_id: string | null }).reversed_by_payment_id,
    ).toBeNull();
    const bank = await h.call('GET', `/api/cash-accounts/${theirs.bank}`, {
      token: theirs.invoice.token,
    });
    h.expect((bank.res.body as { balance: string }).balance).toBe('45.00');
  },
});

// U05 purchase orders (D59). Shop B's order is made (and sent when asked) by B's owner.
const poKey = () => `xs-u05-${Date.now()}-${Math.random()}`;
async function shopBOrder(h: CrossShopHarness, tag: string, send = false) {
  const supplier = await shopBSupplier(h, 'po-' + tag);
  const product = await shopBProduct(h, 'po-' + tag);
  const created = await h.call('POST', '/api/purchase-orders', {
    token: supplier.token,
    idempotencyKey: poKey(),
    body: {
      supplier_id: supplier.id,
      branch_id: SHOP_B_BR1,
      lines: [{ product_id: product.id, quantity: 3, expected_unit_cost: '10.00' }],
    },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  const order = created.res.body as { id: string; updated_at: string };
  if (send) {
    const sent = await h.call('POST', `/api/purchase-orders/${order.id}/send`, {
      token: supplier.token,
    });
    h.expect(sent.res.status, JSON.stringify(sent.res.body)).toBe(200);
  }
  return { order, supplier, product, token: supplier.token };
}
async function orderOf(h: CrossShopHarness, token: string, id: string) {
  const own = await h.call('GET', `/api/purchase-orders/${id}`, { token });
  return own.res.body as { status: string; updated_at: string; invoices: unknown[] };
}
crossShopCase({
  method: 'GET',
  path: '/api/purchase-orders',
  name: "purchase orders list refuses a foreign header, an org key and shop B's supplier or branch",
  async run(h) {
    const theirs = await shopBOrder(h, 'list');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/purchase-orders', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/purchase-orders', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    for (const [query, code] of [
      ['supplier_id=' + theirs.supplier.id, 'SUPPLIER_NOT_FOUND'],
      ['branch_id=' + SHOP_B_BR1, 'BRANCH_NOT_FOUND'],
    ] as const) {
      const res = await h.call('GET', '/api/purchase-orders', { token: a.accessToken, query });
      h.expect(res.res.status).toBe(404);
      h.expect(h.code(res.res)).toBe(code);
    }
    const own = await h.call('GET', '/api/purchase-orders', {
      token: a.accessToken,
      query: 'pageSize=100',
    });
    h.expect(own.res.status).toBe(200);
    h.expect(
      (own.res.body as { items: { id: string }[] }).items.some((x) => x.id === theirs.order.id),
    ).toBe(false);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/purchase-orders/:id',
  name: "shop B's purchase order is not found; a foreign header is refused",
  async run(h) {
    const theirs = await shopBOrder(h, 'get');
    const a = await h.login(OWNER_A);
    const res = await h.call('GET', `/api/purchase-orders/${theirs.order.id}`, {
      token: a.accessToken,
    });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('PURCHASE_ORDER_NOT_FOUND');
    const header = await h.call('GET', `/api/purchase-orders/${theirs.order.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/purchase-orders',
  name: "purchase order create rejects a foreign header, a tenant body and shop B's supplier, branch or product",
  async run(h) {
    const theirs = await shopBOrder(h, 'create');
    const a = await h.login(OWNER_A);
    const own = await h.call('POST', '/api/suppliers', {
      token: a.accessToken,
      body: { name: `Cross-shop PO supplier ${Date.now()}-${Math.random()}` },
    });
    h.expect(own.res.status, JSON.stringify(own.res.body)).toBe(201);
    const ownProduct = await h.call('POST', '/api/products', {
      token: a.accessToken,
      body: { name_ar: 'Cross-shop PO', sku: `XS-PO-${Date.now()}`, cash_price: '1.00' },
    });
    h.expect(ownProduct.res.status, JSON.stringify(ownProduct.res.body)).toBe(201);
    const line = { product_id: (ownProduct.res.body as { id: string }).id, quantity: 1 };
    const body = {
      supplier_id: (own.res.body as { id: string }).id,
      branch_id: SHOP_A_BR1,
      lines: [line],
    };
    const send = (b: object, orgId?: string) =>
      h.call('POST', '/api/purchase-orders', {
        token: a.accessToken,
        idempotencyKey: poKey(),
        body: b,
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(body, SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const injected = await send({ ...body, organization_id: SHOP_B });
    h.expect(injected.res.status).toBe(400);
    const supplier = await send({ ...body, supplier_id: theirs.supplier.id });
    h.expect(supplier.res.status).toBe(404);
    h.expect(h.code(supplier.res)).toBe('SUPPLIER_NOT_FOUND');
    const branch = await send({ ...body, branch_id: SHOP_B_BR1 });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const product = await send({ ...body, lines: [{ ...line, product_id: theirs.product.id }] });
    h.expect(product.res.status).toBe(404);
    h.expect(h.code(product.res)).toBe('PRODUCT_NOT_FOUND');
    // A customer order line that is not this shop's (no API creates one yet: an unknown id).
    const salesLine = await send({
      ...body,
      lines: [{ ...line, sales_order_line_id: theirs.order.id }],
    });
    h.expect(salesLine.res.status).toBe(400);
    h.expect(h.code(salesLine.res)).toBe('SALES_ORDER_LINE_INVALID');
    for (const call of [foreign, injected, supplier, branch, product, salesLine]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});
for (const [method, suffix] of [
  ['PUT', ''],
  ['POST', '/send'],
  ['POST', '/cancel'],
] as const) {
  crossShopCase({
    method,
    path: `/api/purchase-orders/:id${suffix}`,
    name: `${method} purchase order${suffix} rejects another shop's id and leaves it unchanged`,
    async run(h) {
      const theirs = await shopBOrder(h, method.toLowerCase() + suffix.replace('/', '-'));
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/purchase-orders/${theirs.order.id}${suffix}`, {
        token: a.accessToken,
        body:
          suffix === '' ? { notes: 'FOREIGN' } : suffix === '/cancel' ? { reason: 'Not mine' } : {},
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('PURCHASE_ORDER_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_A, foreign.ip)).toBe(0);
      const after = await orderOf(h, theirs.token, theirs.order.id);
      h.expect(after).toMatchObject({ status: 'draft', updated_at: theirs.order.updated_at });
    },
  });
}
crossShopCase({
  method: 'POST',
  path: '/api/purchase-orders/:id/invoice',
  name: "receiving shop B's sent purchase order is not found and creates no invoice",
  async run(h) {
    const theirs = await shopBOrder(h, 'invoice', true);
    const a = await h.login(OWNER_A);
    const send = (orgId?: string) =>
      h.call('POST', `/api/purchase-orders/${theirs.order.id}/invoice`, {
        token: a.accessToken,
        idempotencyKey: poKey(),
        body: {},
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const res = await send();
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('PURCHASE_ORDER_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, res.ip)).toBe(0);
    const after = await orderOf(h, theirs.token, theirs.order.id);
    h.expect(after.status).toBe('sent');
    h.expect(after.invoices).toHaveLength(0);
  },
});

// K02 shifts (D60). Shop B's shift is its owner's; shop A acts as its cashier, so these cases
// never touch the shift the audit suite opens for shop A's owner. Every case closes what it opens.
const CASHIER_A_EMAIL = 'cashier.one@ecotech.test';
const OWNER_B_EMPLOYEE_ID = 'd3000000-0000-0000-0000-000000000021';
const shiftKey = () => `xs-k02-${Date.now()}-${Math.random()}`;
async function openShiftOf(h: CrossShopHarness, email: string, branchId: string) {
  const who = await h.login(email);
  // O03: a shift is opened from the paired POS computer of the branch.
  const pos = await h.pairDevice(
    branchId === SHOP_B_BR1 ? SHOP_B : SHOP_A,
    branchId,
    'Cross-shop POS',
  );
  const current = await h.call('GET', '/api/shifts/current', { token: who.accessToken });
  const existing = (current.res.body as { shift: { id: string } | null }).shift;
  if (existing) return { id: existing.id, token: who.accessToken, deviceToken: pos.token };
  const opened = await h.call('POST', '/api/shifts', {
    token: who.accessToken,
    idempotencyKey: shiftKey(),
    deviceToken: pos.token,
    body: { branch_id: branchId, opening_float: '0' },
  });
  h.expect(opened.res.status, JSON.stringify(opened.res.body)).toBe(201);
  return {
    id: (opened.res.body as { id: string }).id,
    token: who.accessToken,
    deviceToken: pos.token,
  };
}
async function closeShiftOf(
  h: CrossShopHarness,
  shift: { id: string; token: string; deviceToken: string },
) {
  const closed = await h.call('POST', `/api/shifts/${shift.id}/close`, {
    token: shift.token,
    deviceToken: shift.deviceToken,
    body: { counts: {} },
  });
  h.expect(closed.res.status, JSON.stringify(closed.res.body)).toBe(200);
}
async function shopBSafe(h: CrossShopHarness) {
  const b = await h.login(OWNER_B);
  const made = await h.call('POST', '/api/cash-accounts', {
    token: b.accessToken,
    body: { name: `XS safe ${Date.now()}-${Math.random()}`, kind: 'safe', branch_id: SHOP_B_BR1 },
  });
  h.expect(made.res.status, JSON.stringify(made.res.body)).toBe(201);
  return (made.res.body as { id: string }).id;
}
crossShopCase({
  method: 'GET',
  path: '/api/shifts',
  name: "shifts list refuses a foreign header, an org key and shop B's branch or cashier, and never lists B's",
  async run(h) {
    const theirs = await openShiftOf(h, OWNER_B, SHOP_B_BR1);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/shifts', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/shifts', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    for (const [query, code] of [
      ['branch_id=' + SHOP_B_BR1, 'BRANCH_NOT_FOUND'],
      ['employee_id=' + OWNER_B_EMPLOYEE_ID, 'EMPLOYEE_NOT_FOUND'],
    ] as const) {
      const res = await h.call('GET', '/api/shifts', { token: a.accessToken, query });
      h.expect(res.res.status).toBe(404);
      h.expect(h.code(res.res)).toBe(code);
    }
    const own = await h.call('GET', '/api/shifts', { token: a.accessToken, query: 'pageSize=100' });
    h.expect(own.res.status).toBe(200);
    h.expect(
      (own.res.body as { items: { id: string }[] }).items.some((x) => x.id === theirs.id),
    ).toBe(false);
    await closeShiftOf(h, theirs);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/shifts/current',
  name: "the current shift refuses a foreign header and an org key, and is never shop B's",
  async run(h) {
    const theirs = await openShiftOf(h, OWNER_B, SHOP_B_BR1);
    const a = await h.login(CASHIER_A_EMAIL);
    const foreign = await h.call('GET', '/api/shifts/current', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/shifts/current', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const own = await h.call('GET', '/api/shifts/current', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
    h.expect((own.res.body as { shift: { id: string } | null }).shift?.id).not.toBe(theirs.id);
    await closeShiftOf(h, theirs);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/shifts/vaults',
  name: "shift vaults refuse a foreign header, an org key and shop B's branch",
  async run(h) {
    const a = await h.login(CASHIER_A_EMAIL);
    const foreign = await h.call('GET', '/api/shifts/vaults', {
      token: a.accessToken,
      orgId: SHOP_B,
      query: 'branch_id=' + SHOP_A_BR1,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/shifts/vaults', {
      token: a.accessToken,
      query: `branch_id=${SHOP_A_BR1}&organization_id=${SHOP_B}`,
    });
    h.expect(injected.res.status).toBe(400);
    const branch = await h.call('GET', '/api/shifts/vaults', {
      token: a.accessToken,
      query: 'branch_id=' + SHOP_B_BR1,
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/shifts/:id',
  name: "shop B's shift is not found; a foreign header is refused",
  async run(h) {
    const theirs = await openShiftOf(h, OWNER_B, SHOP_B_BR1);
    const a = await h.login(OWNER_A);
    const res = await h.call('GET', `/api/shifts/${theirs.id}`, { token: a.accessToken });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('SHIFT_NOT_FOUND');
    const header = await h.call('GET', `/api/shifts/${theirs.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    await closeShiftOf(h, theirs);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/shifts',
  name: "opening a shift refuses a foreign header, an org id, shop B's branch and a float from B's safe",
  async run(h) {
    const theirSafe = await shopBSafe(h);
    const pos = await h.pairDevice(SHOP_A, SHOP_A_BR1, 'Cross-shop POS');
    const a = await h.login(CASHIER_A_EMAIL);
    const before = await h.call('GET', '/api/shifts/current', { token: a.accessToken });
    const had = (before.res.body as { shift: { id: string } | null }).shift?.id ?? null;
    const send = (body: object, orgId?: string) =>
      h.call('POST', '/api/shifts', {
        token: a.accessToken,
        idempotencyKey: shiftKey(),
        deviceToken: pos.token,
        body,
        ...(orgId ? { orgId } : {}),
      });
    const body = { branch_id: SHOP_A_BR1, opening_float: '0' };
    const foreign = await send(body, SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const injected = await send({ ...body, organization_id: SHOP_B });
    h.expect(injected.res.status).toBe(400);
    const branch = await send({ ...body, branch_id: SHOP_B_BR1 });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    for (const call of [foreign, injected, branch]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    if (!had) {
      // With no open shift the float is checked: shop B's safe is not a vault of this branch.
      const vault = await send({ ...body, opening_float: '5.00', vault_id: theirSafe });
      h.expect(vault.res.status).toBe(400);
      h.expect(h.code(vault.res)).toBe('VAULT_INVALID');
      h.expect(await h.auditRowsFrom(SHOP_A, vault.ip)).toBe(0);
    }
    const after = await h.call('GET', '/api/shifts/current', { token: a.accessToken });
    h.expect((after.res.body as { shift: { id: string } | null }).shift?.id ?? null).toBe(had);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/shifts/:id/cash',
  name: "cash on shop B's shift is not found; shop B's safe is not a vault for shop A's shift",
  async run(h) {
    const theirs = await openShiftOf(h, OWNER_B, SHOP_B_BR1);
    const theirSafe = await shopBSafe(h);
    const mine = await openShiftOf(h, CASHIER_A_EMAIL, SHOP_A_BR1);
    const body = { direction: 'in', amount: '1.00', vault_id: theirSafe, note: 'Cross-shop case' };
    const send = (id: string, orgId?: string) =>
      h.call('POST', `/api/shifts/${id}/cash`, {
        token: mine.token,
        deviceToken: mine.deviceToken,
        idempotencyKey: shiftKey(),
        body,
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(theirs.id, SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const res = await send(theirs.id);
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('SHIFT_NOT_FOUND');
    const vault = await send(mine.id);
    h.expect(vault.res.status).toBe(400);
    h.expect(h.code(vault.res)).toBe('VAULT_INVALID');
    for (const call of [res, vault]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    await closeShiftOf(h, mine);
    await closeShiftOf(h, theirs);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/shifts/:id/close',
  name: "closing shop B's shift is not found and leaves it open",
  async run(h) {
    const theirs = await openShiftOf(h, OWNER_B, SHOP_B_BR1);
    const a = await h.login(OWNER_A);
    const send = (orgId?: string) =>
      h.call('POST', `/api/shifts/${theirs.id}/close`, {
        token: a.accessToken,
        body: { counts: {} },
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const res = await send();
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('SHIFT_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
    const own = await h.call('GET', `/api/shifts/${theirs.id}`, { token: theirs.token });
    h.expect((own.res.body as { status: string }).status).toBe('open');
    await closeShiftOf(h, theirs);
  },
});

// K03 expenses (D61). Shop B's category and expense belong to its owner; shop A's owner acts.
const expenseKey = () => `xs-k03-${Date.now()}-${Math.random()}`;
async function shopBExpenseCategory(h: CrossShopHarness) {
  const b = await h.login(OWNER_B);
  const name = `XS category ${Date.now()}-${Math.random()}`;
  const made = await h.call('POST', '/api/expense-categories', {
    token: b.accessToken,
    body: { name },
  });
  h.expect(made.res.status, JSON.stringify(made.res.body)).toBe(201);
  return { id: (made.res.body as { id: string }).id, name, token: b.accessToken };
}
async function shopBExpense(h: CrossShopHarness) {
  const category = await shopBExpenseCategory(h);
  const safe = await shopBSafe(h);
  const funded = await h.call('POST', `/api/cash-accounts/${safe}/opening`, {
    token: category.token,
    idempotencyKey: expenseKey(),
    body: { amount: '20.00', note: 'Cross-shop case' },
  });
  h.expect(funded.res.status, JSON.stringify(funded.res.body)).toBe(200);
  const posted = await h.call('POST', '/api/expenses', {
    token: category.token,
    idempotencyKey: expenseKey(),
    body: {
      category_id: category.id,
      amount: '5.00',
      branch_id: SHOP_B_BR1,
      cash_account_id: safe,
    },
  });
  h.expect(posted.res.status, JSON.stringify(posted.res.body)).toBe(201);
  return { id: (posted.res.body as { id: string }).id, category, safe, token: category.token };
}
crossShopCase({
  method: 'GET',
  path: '/api/expense-categories',
  name: "expense categories refuse a foreign header and an org key, and never list shop B's",
  async run(h) {
    const theirs = await shopBExpenseCategory(h);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/expense-categories', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/expense-categories', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const own = await h.call('GET', '/api/expense-categories', {
      token: a.accessToken,
      query: 'include_archived=true',
    });
    h.expect(own.res.status).toBe(200);
    h.expect((own.res.body as { id: string }[]).some((c) => c.id === theirs.id)).toBe(false);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/expense-categories',
  name: 'creating an expense category refuses a foreign header and an org id',
  async run(h) {
    const a = await h.login(OWNER_A);
    const name = `XS refused ${Date.now()}-${Math.random()}`;
    const foreign = await h.call('POST', '/api/expense-categories', {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { name },
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/expense-categories', {
      token: a.accessToken,
      body: { name, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    for (const call of [foreign, injected]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});
for (const [method, suffix, body, what] of [
  ['PATCH', '', { name: 'Taken over' }, 'renaming'],
  ['POST', '/archive', undefined, 'archiving'],
  ['POST', '/restore', undefined, 'restoring'],
] as const) {
  crossShopCase({
    method,
    path: `/api/expense-categories/:id${suffix}`,
    name: `${what} shop B's expense category is not found and changes nothing`,
    async run(h) {
      const theirs = await shopBExpenseCategory(h);
      const a = await h.login(OWNER_A);
      const send = (orgId?: string) =>
        h.call(method, `/api/expense-categories/${theirs.id}${suffix}`, {
          token: a.accessToken,
          ...(body ? { body } : {}),
          ...(orgId ? { orgId } : {}),
        });
      const foreign = await send(SHOP_B);
      h.expect(foreign.res.status).toBe(403);
      const res = await send();
      h.expect(res.res.status).toBe(404);
      h.expect(h.code(res.res)).toBe('EXPENSE_CATEGORY_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_A, res.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
      const list = await h.call('GET', '/api/expense-categories', { token: theirs.token });
      const row = (list.res.body as { id: string; name: string }[]).find((c) => c.id === theirs.id);
      h.expect(row?.name).toBe(theirs.name);
    },
  });
}
crossShopCase({
  method: 'GET',
  path: '/api/expenses',
  name: "expenses refuse a foreign header, an org key and shop B's branch or category, and never list B's",
  async run(h) {
    const theirs = await shopBExpense(h);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/expenses', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/expenses', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    for (const [query, code] of [
      ['branch_id=' + SHOP_B_BR1, 'BRANCH_NOT_FOUND'],
      ['category_id=' + theirs.category.id, 'EXPENSE_CATEGORY_NOT_FOUND'],
    ] as const) {
      const res = await h.call('GET', '/api/expenses', { token: a.accessToken, query });
      h.expect(res.res.status).toBe(404);
      h.expect(h.code(res.res)).toBe(code);
    }
    const own = await h.call('GET', '/api/expenses', {
      token: a.accessToken,
      query: 'pageSize=100',
    });
    h.expect(own.res.status).toBe(200);
    h.expect(
      (own.res.body as { items: { id: string }[] }).items.some((x) => x.id === theirs.id),
    ).toBe(false);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/expenses/report',
  name: "the expense report refuses a foreign header, an org key and shop B's branch",
  async run(h) {
    const a = await h.login(OWNER_A);
    const period = 'from=2026-01-01&to=2026-12-31';
    const foreign = await h.call('GET', '/api/expenses/report', {
      token: a.accessToken,
      orgId: SHOP_B,
      query: period,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/expenses/report', {
      token: a.accessToken,
      query: `${period}&organization_id=${SHOP_B}`,
    });
    h.expect(injected.res.status).toBe(400);
    const branch = await h.call('GET', '/api/expenses/report', {
      token: a.accessToken,
      query: `${period}&branch_id=${SHOP_B_BR1}`,
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/expenses/:id',
  name: "shop B's expense is not found; a foreign header is refused",
  async run(h) {
    const theirs = await shopBExpense(h);
    const a = await h.login(OWNER_A);
    const res = await h.call('GET', `/api/expenses/${theirs.id}`, { token: a.accessToken });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('EXPENSE_NOT_FOUND');
    const header = await h.call('GET', `/api/expenses/${theirs.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/expenses',
  name: "an expense refuses a foreign header, an org id and shop B's category, branch and safe",
  async run(h) {
    const theirs = await shopBExpense(h);
    const a = await h.login(OWNER_A);
    const mine = await h.call('POST', '/api/expense-categories', {
      token: a.accessToken,
      body: { name: `XS own ${Date.now()}-${Math.random()}` },
    });
    h.expect(mine.res.status, JSON.stringify(mine.res.body)).toBe(201);
    const body = {
      category_id: (mine.res.body as { id: string }).id,
      amount: '1.00',
      branch_id: SHOP_A_BR1,
      cash_account_id: theirs.safe,
    };
    const send = (sent: object, orgId?: string) =>
      h.call('POST', '/api/expenses', {
        token: a.accessToken,
        idempotencyKey: expenseKey(),
        body: sent,
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(body, SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const injected = await send({ ...body, organization_id: SHOP_B });
    h.expect(injected.res.status).toBe(400);
    const category = await send({ ...body, category_id: theirs.category.id });
    h.expect(category.res.status).toBe(404);
    h.expect(h.code(category.res)).toBe('EXPENSE_CATEGORY_NOT_FOUND');
    const branch = await send({ ...body, branch_id: SHOP_B_BR1 });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    const safe = await send(body);
    h.expect(safe.res.status).toBe(400);
    h.expect(h.code(safe.res)).toBe('VAULT_INVALID');
    for (const call of [foreign, injected, category, branch, safe]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    const account = await h.call('GET', `/api/cash-accounts/${theirs.safe}`, {
      token: theirs.token,
    });
    h.expect((account.res.body as { balance: string }).balance).toBe('15.00');
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/expenses/:id/reverse',
  name: "reversing shop B's expense is not found and leaves it as it is",
  async run(h) {
    const theirs = await shopBExpense(h);
    const a = await h.login(OWNER_A);
    const send = (orgId?: string) =>
      h.call('POST', `/api/expenses/${theirs.id}/reverse`, {
        token: a.accessToken,
        idempotencyKey: expenseKey(),
        body: { reason: 'Cross-shop case' },
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const res = await send();
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('EXPENSE_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_A, res.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
    const own = await h.call('GET', `/api/expenses/${theirs.id}`, { token: theirs.token });
    h.expect(
      (own.res.body as { reversed_by_expense_id: string | null }).reversed_by_expense_id,
    ).toBeNull();
  },
});

// S01 sales (D62). Shop A sells as its cashier (in a shift opened for the case); shop B's sale
// is its owner's. Refused calls move no stock and no cash, so shop A's shift closes on nothing.
const saleKey = () => `xs-s01-${Date.now()}-${Math.random()}`;
/** A sale of one new product by shop B's owner, in their open shift (left open for the caller). */
async function shopBSale(h: CrossShopHarness) {
  const product = await shopBProduct(h, 'sale');
  const stocked = await h.call('POST', '/api/stock/adjustments', {
    token: product.token,
    idempotencyKey: key('sale-stock'),
    body: {
      branch_id: SHOP_B_BR1,
      reason: 'found',
      lines: [{ product_id: product.id, quantity: 1 }],
    },
  });
  h.expect(stocked.res.status, JSON.stringify(stocked.res.body)).toBe(201);
  const shift = await openShiftOf(h, OWNER_B, SHOP_B_BR1);
  const lines = [{ product_id: product.id, quantity: 1 }];
  const quote = await h.call('POST', '/api/sales/quote', {
    token: shift.token,
    deviceToken: shift.deviceToken,
    body: { lines },
  });
  h.expect(quote.res.status, JSON.stringify(quote.res.body)).toBe(200);
  const sold = await h.call('POST', '/api/sales', {
    token: shift.token,
    deviceToken: shift.deviceToken,
    idempotencyKey: saleKey(),
    body: { lines, expected_total: (quote.res.body as { total: string }).total },
  });
  h.expect(sold.res.status, JSON.stringify(sold.res.body)).toBe(201);
  return { id: (sold.res.body as { id: string }).id, shift };
}
/** Shop B's shift holds the sale's cash: closed with nothing counted and a reason. */
async function closeShiftShort(
  h: CrossShopHarness,
  shift: { id: string; token: string; deviceToken: string },
) {
  const closed = await h.call('POST', `/api/shifts/${shift.id}/close`, {
    token: shift.token,
    deviceToken: shift.deviceToken,
    body: { counts: {}, difference_reason: 'Cross-shop case' },
  });
  h.expect(closed.res.status, JSON.stringify(closed.res.body)).toBe(200);
}
crossShopCase({
  method: 'POST',
  path: '/api/sales/quote',
  name: "a quote refuses a foreign header, an org id and shop B's product",
  async run(h) {
    const theirs = await shopBProduct(h, 'quote');
    const mine = await openShiftOf(h, CASHIER_A_EMAIL, SHOP_A_BR1);
    const lines = [{ product_id: theirs.id, quantity: 1 }];
    const foreign = await h.call('POST', '/api/sales/quote', {
      token: mine.token,
      deviceToken: mine.deviceToken,
      orgId: SHOP_B,
      body: { lines },
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/sales/quote', {
      token: mine.token,
      deviceToken: mine.deviceToken,
      body: { lines, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const product = await h.call('POST', '/api/sales/quote', {
      token: mine.token,
      deviceToken: mine.deviceToken,
      body: { lines },
    });
    h.expect(product.res.status).toBe(404);
    h.expect(h.code(product.res)).toBe('PRODUCT_NOT_FOUND');
    await closeShiftOf(h, mine);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/sales',
  name: "a sale refuses a foreign header, an org id, shop B's product and an unknown customer; nothing is written",
  async run(h) {
    const theirs = await shopBProduct(h, 'sell');
    const mine = await openShiftOf(h, CASHIER_A_EMAIL, SHOP_A_BR1);
    const body = { lines: [{ product_id: theirs.id, quantity: 1 }], expected_total: '10.00' };
    const send = (sent: object, orgId?: string) =>
      h.call('POST', '/api/sales', {
        token: mine.token,
        deviceToken: mine.deviceToken,
        idempotencyKey: saleKey(),
        body: sent,
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(body, SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const injected = await send({ ...body, organization_id: SHOP_B });
    h.expect(injected.res.status).toBe(400);
    const branch = await send({ ...body, branch_id: SHOP_B_BR1 });
    h.expect(branch.res.status).toBe(400);
    const product = await send(body);
    h.expect(product.res.status).toBe(404);
    h.expect(h.code(product.res)).toBe('PRODUCT_NOT_FOUND');
    const customer = await send({ ...body, customer_id: '00000000-0000-4000-8000-00000000c0de' });
    h.expect(customer.res.status).toBe(404);
    h.expect(h.code(customer.res)).toBe('CUSTOMER_NOT_FOUND');
    // S02 (D64): shop A sells its own stocked product, paying into shop B's bank or with shop B's
    // customer's store credit.
    const owner = await h.login(OWNER_A);
    const own = await h.call('POST', '/api/products', {
      token: owner.accessToken,
      body: { name_ar: 'Cross-shop pay', sku: `XS-PAY-${Date.now()}`, cash_price: '10.00' },
    });
    h.expect(own.res.status, JSON.stringify(own.res.body)).toBe(201);
    const ownId = (own.res.body as { id: string }).id;
    const stocked = await h.call('POST', '/api/stock/adjustments', {
      token: owner.accessToken,
      idempotencyKey: key('pay-stock'),
      body: {
        branch_id: SHOP_A_BR1,
        reason: 'found',
        lines: [{ product_id: ownId, quantity: 1 }],
      },
    });
    h.expect(stocked.res.status, JSON.stringify(stocked.res.body)).toBe(201);
    const ownLines = [{ product_id: ownId, quantity: 1 }];
    const quote = await h.call('POST', '/api/sales/quote', {
      token: mine.token,
      deviceToken: mine.deviceToken,
      body: { lines: ownLines },
    });
    h.expect(quote.res.status, JSON.stringify(quote.res.body)).toBe(200);
    const total = (quote.res.body as { total: string }).total;
    const theirBank = await cashAccountOf(h, OWNER_B);
    const bank = await send({
      lines: ownLines,
      expected_total: total,
      payments: [
        { method: 'bank_transfer', amount: total, cash_account_id: theirBank, reference: 'XS-1' },
      ],
    });
    h.expect(bank.res.status).toBe(400);
    h.expect(h.code(bank.res)).toBe('VAULT_INVALID');
    const theirCustomer = await shopBCustomer(h, 'pay');
    const credit = await send({
      lines: ownLines,
      expected_total: total,
      customer_id: theirCustomer.id,
      payments: [{ method: 'store_credit', amount: total }],
    });
    h.expect(credit.res.status).toBe(404);
    h.expect(h.code(credit.res)).toBe('CUSTOMER_NOT_FOUND');
    for (const call of [foreign, injected, branch, product, customer, bank, credit]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    // Nothing was sold: the shift still expects nothing and closes on an empty count.
    await closeShiftOf(h, mine);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/sales/payment-accounts',
  name: "the payment accounts refuse a foreign header and never list shop B's bank",
  async run(h) {
    const theirBank = await cashAccountOf(h, OWNER_B);
    const mine = await openShiftOf(h, CASHIER_A_EMAIL, SHOP_A_BR1);
    const foreign = await h.call('GET', '/api/sales/payment-accounts', {
      token: mine.token,
      deviceToken: mine.deviceToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const own = await h.call('GET', '/api/sales/payment-accounts', { token: mine.token });
    h.expect(own.res.status, JSON.stringify(own.res.body)).toBe(200);
    const items = (own.res.body as { items: { id: string }[] }).items;
    h.expect(items.some((a) => a.id === theirBank)).toBe(false);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
    await closeShiftOf(h, mine);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/sales/:id',
  name: "shop B's sale is not found; a foreign header is refused",
  async run(h) {
    const theirs = await shopBSale(h);
    const a = await h.login(OWNER_A);
    const res = await h.call('GET', `/api/sales/${theirs.id}`, { token: a.accessToken });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('SALE_NOT_FOUND');
    const header = await h.call('GET', `/api/sales/${theirs.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    const own = await h.call('GET', `/api/sales/${theirs.id}`, { token: theirs.shift.token });
    h.expect(own.res.status).toBe(200);
    await closeShiftShort(h, theirs.shift);
  },
});

// S03 discounts (D65). Shop B's over-cap request is its cashier's (shop B sets no cap: 0 %), made
// on one of its own products; shop A's people can't read, cancel or decide it, and the pending
// list of shop A never shows it.
const CASHIER_B_EMAIL = 'cashier.two@ecotech.test';
async function shopBApproval(h: CrossShopHarness) {
  const product = await shopBProduct(h, 'disc');
  const who = await h.login(CASHIER_B_EMAIL);
  const made = await h.call('POST', '/api/sales/discount-approvals', {
    token: who.accessToken,
    body: {
      branch_id: SHOP_B_BR1,
      lines: [{ product_id: product.id, quantity: 1, discount: { type: 'percent', value: '10' } }],
      reason: 'Cross-shop case',
    },
  });
  h.expect(made.res.status, JSON.stringify(made.res.body)).toBe(201);
  return { id: (made.res.body as { approval_id: string }).approval_id, token: who.accessToken };
}
crossShopCase({
  method: 'POST',
  path: '/api/sales/discount-approvals',
  name: "a request refuses a foreign header, an org id, shop B's branch and shop B's product",
  async run(h) {
    const theirs = await shopBProduct(h, 'discreq');
    const a = await h.login(CASHIER_A_EMAIL);
    const body = {
      branch_id: SHOP_A_BR1,
      lines: [{ product_id: theirs.id, quantity: 1, discount: { type: 'percent', value: '10' } }],
      reason: 'Cross-shop case',
    };
    const send = (sent: object, orgId?: string) =>
      h.call('POST', '/api/sales/discount-approvals', {
        token: a.accessToken,
        body: sent,
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(body, SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const injected = await send({ ...body, organization_id: SHOP_B });
    h.expect(injected.res.status).toBe(400);
    const branch = await send({ ...body, branch_id: SHOP_B_BR1 });
    h.expect(branch.res.status).toBe(403);
    h.expect(h.code(branch.res)).toBe('BRANCH_DENIED');
    const product = await send(body);
    h.expect(product.res.status).toBe(404);
    h.expect(h.code(product.res)).toBe('PRODUCT_NOT_FOUND');
    for (const call of [foreign, injected, branch, product]) {
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/sales/discount-approvals/:id',
  name: "shop B's approval is not found for shop A; a foreign header is refused",
  async run(h) {
    const theirs = await shopBApproval(h);
    const a = await h.login(OWNER_A);
    const res = await h.call('GET', `/api/sales/discount-approvals/${theirs.id}`, {
      token: a.accessToken,
    });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('APPROVAL_NOT_FOUND');
    const header = await h.call('GET', `/api/sales/discount-approvals/${theirs.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    const own = await h.call('GET', `/api/sales/discount-approvals/${theirs.id}`, {
      token: theirs.token,
    });
    h.expect(own.res.status, JSON.stringify(own.res.body)).toBe(200);
    h.expect((own.res.body as { status: string }).status).toBe('pending');
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/sales/discount-approvals/:id/cancel',
  name: "shop A can't cancel shop B's approval; its own requester can",
  async run(h) {
    const theirs = await shopBApproval(h);
    const a = await h.login(CASHIER_A_EMAIL);
    const res = await h.call('POST', `/api/sales/discount-approvals/${theirs.id}/cancel`, {
      token: a.accessToken,
    });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('APPROVAL_NOT_FOUND');
    const header = await h.call('POST', `/api/sales/discount-approvals/${theirs.id}/cancel`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    h.expect(await h.auditRowsFrom(SHOP_B, res.ip)).toBe(0);
    const own = await h.call('POST', `/api/sales/discount-approvals/${theirs.id}/cancel`, {
      token: theirs.token,
    });
    h.expect(own.res.status, JSON.stringify(own.res.body)).toBe(200);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/approvals',
  name: "the approvals list refuses a foreign header and never lists shop B's requests",
  async run(h) {
    const theirs = await shopBApproval(h);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/approvals', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/approvals', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const own = await h.call('GET', '/api/approvals', { token: a.accessToken });
    h.expect(own.res.status, JSON.stringify(own.res.body)).toBe(200);
    const items = (own.res.body as { items: { id: string }[] }).items;
    h.expect(items.some((i) => i.id === theirs.id)).toBe(false);
    const b = await h.login(OWNER_B);
    const theirList = await h.call('GET', '/api/approvals', { token: b.accessToken });
    h.expect(
      (theirList.res.body as { items: { id: string }[] }).items.some((i) => i.id === theirs.id),
    ).toBe(true);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/approvals/:id/decide',
  name: "shop A's owner can't decide shop B's approval; it stays pending",
  async run(h) {
    const theirs = await shopBApproval(h);
    const a = await h.login(OWNER_A);
    const res = await h.call('POST', `/api/approvals/${theirs.id}/decide`, {
      token: a.accessToken,
      body: { approve: true },
    });
    h.expect(res.res.status).toBe(404);
    h.expect(h.code(res.res)).toBe('APPROVAL_NOT_FOUND');
    const header = await h.call('POST', `/api/approvals/${theirs.id}/decide`, {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { approve: true },
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('POST', `/api/approvals/${theirs.id}/decide`, {
      token: a.accessToken,
      body: { approve: true, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    for (const call of [res, header, injected]) {
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    const own = await h.call('GET', `/api/sales/discount-approvals/${theirs.id}`, {
      token: theirs.token,
    });
    h.expect((own.res.body as { status: string }).status).toBe('pending');
  },
});

// S07 history is branch-scoped; void never reaches another tenant's sale.
crossShopCase({
  method: 'GET',
  path: '/api/sales',
  name: 'history excludes shop B and rejects an injected organization',
  async run(h) {
    const a = await h.login(OWNER_A);
    const b = await shopBSale(h);
    const rows = await h.call('GET', '/api/sales', { token: a.accessToken });
    h.expect(rows.res.status).toBe(200);
    h.expect((rows.res.body as { items: { id: string }[] }).items.some((r) => r.id === b.id)).toBe(
      false,
    );
    const injected = await h.call('GET', '/api/sales', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    await closeShiftShort(h, b.shift);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/sales/:id/void',
  name: 'foreign sale is 404 without audit or a reversal',
  async run(h) {
    const a = await h.login(OWNER_A);
    const b = await shopBSale(h);
    const attempt = await h.call('POST', '/api/sales/' + b.id + '/void', {
      token: a.accessToken,
      idempotencyKey: saleKey(),
      body: { reason: 'S07 cross-shop' },
    });
    h.expect(attempt.res.status).toBe(404);
    h.expect(h.code(attempt.res)).toBe('SALE_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, attempt.ip)).toBe(0);
    await closeShiftShort(h, b.shift);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/sales/:id/receipt-prints',
  name: "another shop's sale is 404 and no print is logged",
  async run(h) {
    const a = await h.login(OWNER_A);
    const b = await shopBSale(h);
    const attempt = await h.call('POST', '/api/sales/' + b.id + '/receipt-prints', {
      token: a.accessToken,
    });
    h.expect(attempt.res.status).toBe(404);
    h.expect(h.code(attempt.res)).toBe('SALE_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, attempt.ip)).toBe(0);
    const header = await h.call('POST', '/api/sales/' + b.id + '/receipt-prints', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    // Its own shop prints the original, then a copy, and the details count both.
    const first = await h.call('POST', '/api/sales/' + b.id + '/receipt-prints', {
      token: b.shift.token,
      deviceToken: b.shift.deviceToken,
    });
    h.expect(first.res.status, JSON.stringify(first.res.body)).toBe(201);
    h.expect(first.res.body).toEqual({ print_no: 1, copy: false });
    const second = await h.call('POST', '/api/sales/' + b.id + '/receipt-prints', {
      token: b.shift.token,
      deviceToken: b.shift.deviceToken,
    });
    h.expect(second.res.body).toEqual({ print_no: 2, copy: true });
    const detail = await h.call('GET', '/api/sales/' + b.id, { token: b.shift.token });
    h.expect((detail.res.body as { receipt_prints: number }).receipt_prints).toBe(2);
    await closeShiftShort(h, b.shift);
  },
});

// S12: each request uses caller JWT; foreign claims/lines look absent.
async function shopBClaim(h: CrossShopHarness) {
  const sale = await shopBSale(h);
  const detail = await h.call('GET', '/api/sales/' + sale.id, { token: sale.shift.token });
  h.expect(detail.res.status).toBe(200);
  const line = (detail.res.body as { lines: { id: string }[]; number: string }).lines[0]!.id;
  const claim = await h.call('POST', '/api/warranty/claims', {
    token: sale.shift.token,
    deviceToken: sale.shift.deviceToken,
    idempotencyKey: key('warranty'),
    body: { sale_line_id: line, issue: 'Broken item', condition: 'Used item' },
  });
  h.expect(claim.res.status, JSON.stringify(claim.res.body)).toBe(201);
  await closeShiftShort(h, sale.shift);
  return {
    id: (claim.res.body as { claim_id: string }).claim_id,
    line,
    number: (detail.res.body as { number: string }).number,
    token: sale.shift.token,
    deviceToken: sale.shift.deviceToken,
  };
}
crossShopCase({
  method: 'GET',
  path: '/api/warranty/lookup',
  name: 'warranty lookup cannot see foreign receipt',
  async run(h) {
    const b = await shopBClaim(h);
    const a = await h.login(OWNER_A);
    const r = await h.call('GET', '/api/warranty/lookup', {
      token: a.accessToken,
      query: 'sale_number=' + encodeURIComponent(b.number),
    });
    h.expect(r.res.status).toBe(200);
    h.expect(
      (r.res.body as { items: { sale_line_id: string }[] }).items.some(
        (l) => l.sale_line_id === b.line,
      ),
    ).toBe(false);
    const injected = await h.call('GET', '/api/warranty/lookup', {
      token: a.accessToken,
      query: 'serial=A&organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/warranty/claims',
  name: 'claims list excludes foreign claims',
  async run(h) {
    const b = await shopBClaim(h);
    const a = await h.login(OWNER_A);
    const r = await h.call('GET', '/api/warranty/claims', { token: a.accessToken });
    h.expect(r.res.status).toBe(200);
    h.expect((r.res.body as { items: { id: string }[] }).items.some((c) => c.id === b.id)).toBe(
      false,
    );
    const injected = await h.call('GET', '/api/warranty/claims', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
  },
});
for (const action of ['detail', 'move', 'refund'] as const) {
  crossShopCase({
    method: action === 'detail' ? 'GET' : 'POST',
    path: '/api/warranty/claims/:id' + (action === 'detail' ? '' : '/' + action),
    name: 'foreign warranty ' + action + ' is 404 without writes',
    async run(h) {
      const b = await shopBClaim(h);
      const a = await h.login(OWNER_A);
      const r = await h.call(
        action === 'detail' ? 'GET' : 'POST',
        '/api/warranty/claims/' + b.id + (action === 'detail' ? '' : '/' + action),
        {
          token: a.accessToken,
          ...(action === 'move' ? { body: { to: 'rejected', note: 'Foreign decision' } } : {}),
        },
      );
      h.expect(r.res.status).toBe(404);
      h.expect(h.code(r.res)).toBe('NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_B, r.ip)).toBe(0);
      const own = await h.call('GET', '/api/warranty/claims/' + b.id, { token: b.token });
      h.expect((own.res.body as { status: string }).status).toBe('open');
    },
  });
}
crossShopCase({
  method: 'POST',
  path: '/api/warranty/claims',
  name: 'foreign sold line cannot open a claim',
  async run(h) {
    const b = await shopBClaim(h);
    const a = await h.login(OWNER_A);
    const r = await h.call('POST', '/api/warranty/claims', {
      token: a.accessToken,
      idempotencyKey: key('foreign-claim'),
      body: { sale_line_id: b.line, issue: 'Broken item', condition: 'Used item' },
    });
    h.expect(r.res.status).toBe(404);
    h.expect(h.code(r.res)).toBe('SALE_LINE_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_B, r.ip)).toBe(0);
    const injected = await h.call('POST', '/api/warranty/claims', {
      token: a.accessToken,
      idempotencyKey: key('inject-claim'),
      body: {
        sale_line_id: b.line,
        issue: 'Broken item',
        condition: 'Used item',
        organization_id: SHOP_B,
      },
    });
    h.expect(injected.res.status).toBe(400);
  },
});

// T02 ETA e-receipts (D67). The harness can't make a POS or a receipt in shop B, so these cover
// the shop header, an injected shop key and an id that isn't the caller's; shop B's real device
// and receipt are tried in src/eta/eta.integration.test.ts.
const T02_UNKNOWN_ID = '00000000-0000-4000-8000-000000000000';
const T02_SETTINGS_OFF = {
  environment: 'preprod',
  client_id: null,
  activity_code: null,
  is_enabled: false,
};
const T02_DEVICE_BODY = {
  eta_serial: 'T02-CROSS',
  eta_os_version: 'os',
  eta_model_framework: '1',
  eta_status: 'pending',
};

crossShopCase({
  method: 'GET',
  path: '/api/eta/settings',
  name: 'ETA settings are read for the caller shop only, and never show a secret',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/eta/settings', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    h.expect(h.code(foreign.res)).toBe('SHOP_NOT_ALLOWED');
    const injected = await h.call('GET', '/api/eta/settings', {
      token: a.accessToken,
      query: 'orgId=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const own = await h.call('GET', '/api/eta/settings', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
    h.expect(Object.keys(own.res.body as object).sort()).toEqual([
      'activity_code',
      'client_id',
      'environment',
      'has_client_secret',
      'is_enabled',
      'updated_at',
    ]);
  },
});

crossShopCase({
  method: 'PUT',
  path: '/api/eta/settings',
  name: "shop A's owner can't set shop B's ETA settings",
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('PUT', '/api/eta/settings', {
      token: a.accessToken,
      orgId: SHOP_B,
      body: T02_SETTINGS_OFF,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('PUT', '/api/eta/settings', {
      token: a.accessToken,
      body: { ...T02_SETTINGS_OFF, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    for (const call of [foreign, injected]) {
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/eta/settings/test',
  name: "the ETA connection test takes the caller shop's own devices only",
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('POST', '/api/eta/settings/test', {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { device_id: T02_UNKNOWN_ID },
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/eta/settings/test', {
      token: a.accessToken,
      body: { device_id: T02_UNKNOWN_ID, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const unknown = await h.call('POST', '/api/eta/settings/test', {
      token: a.accessToken,
      body: { device_id: T02_UNKNOWN_ID },
    });
    h.expect(unknown.res.status).toBe(404);
    h.expect(h.code(unknown.res)).toBe('DEVICE_NOT_FOUND');
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/eta/submissions/:id/retry',
  name: "a receipt that isn't the caller shop's can't be retried",
  async run(h) {
    const a = await h.login(OWNER_A);
    const path = `/api/eta/submissions/${T02_UNKNOWN_ID}/retry`;
    const foreign = await h.call('POST', path, { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const unknown = await h.call('POST', path, { token: a.accessToken });
    h.expect(unknown.res.status).toBe(404);
    h.expect(h.code(unknown.res)).toBe('FISCAL_NOT_FOUND');
    for (const call of [foreign, unknown]) {
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});

// T03: the ETA monitor. Another shop's header is refused (403); a receipt that isn't the caller shop's
// (here an id that exists nowhere) is FISCAL_NOT_FOUND, and nothing is written for shop B.
for (const [method, suffix, body] of [
  ['GET', '', undefined],
  ['POST', '/retry', undefined],
  ['POST', '/correct', undefined],
  ['POST', '/check-now', undefined],
  ['POST', '/assign-device', { device_id: T02_UNKNOWN_ID }],
] as const) {
  crossShopCase({
    method,
    path: suffix === '' ? '/api/fiscal/:id' : `/api/fiscal/:id${suffix}`,
    name: "a receipt that isn't the caller shop's is not found",
    async run(h) {
      const a = await h.login(OWNER_A);
      const path = `/api/fiscal/${T02_UNKNOWN_ID}${suffix}`;
      const foreign = await h.call(method, path, {
        token: a.accessToken,
        orgId: SHOP_B,
        ...(body ? { body } : {}),
      });
      h.expect(foreign.res.status).toBe(403);
      const unknown = await h.call(method, path, {
        token: a.accessToken,
        ...(body ? { body } : {}),
      });
      h.expect(unknown.res.status).toBe(404);
      h.expect(h.code(unknown.res)).toBe('FISCAL_NOT_FOUND');
      for (const call of [foreign, unknown]) {
        h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
      }
    },
  });
}

crossShopCase({
  method: 'GET',
  path: '/api/fiscal',
  name: 'the receipt list is the caller shop own',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/fiscal', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/fiscal', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const own = await h.call('GET', '/api/fiscal', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/fiscal/summary',
  name: 'the alert counts are the caller shop own',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/fiscal/summary', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const own = await h.call('GET', '/api/fiscal/summary', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/fiscal/day-summary',
  name: "shop B's branch has no day summary for the caller",
  async run(h) {
    const a = await h.login(OWNER_A);
    const query = `branch_id=${SHOP_B_BR1}&date=2026-10-12`;
    const foreign = await h.call('GET', '/api/fiscal/day-summary', {
      token: a.accessToken,
      orgId: SHOP_B,
      query,
    });
    h.expect(foreign.res.status).toBe(403);
    const other = await h.call('GET', '/api/fiscal/day-summary', { token: a.accessToken, query });
    h.expect(other.res.status).toBe(403);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/fiscal/retry-many',
  name: "another shop's receipts are skipped, never retried",
  async run(h) {
    const a = await h.login(OWNER_A);
    const body = { ids: [T02_UNKNOWN_ID] };
    const foreign = await h.call('POST', '/api/fiscal/retry-many', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    const own = await h.call('POST', '/api/fiscal/retry-many', { token: a.accessToken, body });
    h.expect(own.res.status).toBe(200);
    h.expect(own.res.body).toEqual({
      done: 0,
      skipped: [{ id: T02_UNKNOWN_ID, reason: 'FISCAL_NOT_FOUND' }],
    });
    for (const call of [foreign, own]) {
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/devices',
  name: 'the device list is the caller shop own, and never shows a key',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/devices', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/devices', {
      token: a.accessToken,
      query: 'orgId=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const own = await h.call('GET', '/api/devices', { token: a.accessToken });
    h.expect(own.res.status).toBe(200);
    for (const device of own.res.body as { branch_id: string }[]) {
      h.expect([SHOP_A_BR1, SHOP_A_BR2]).toContain(device.branch_id);
      h.expect(Object.keys(device).filter((key) => /vault|^preshared_key$/.test(key))).toEqual([]);
    }
  },
});

crossShopCase({
  method: 'PUT',
  path: '/api/devices/:id/eta',
  name: "a device that isn't the caller shop's can't be registered with the ETA",
  async run(h) {
    const a = await h.login(OWNER_A);
    const path = `/api/devices/${T02_UNKNOWN_ID}/eta`;
    const foreign = await h.call('PUT', path, {
      token: a.accessToken,
      orgId: SHOP_B,
      body: T02_DEVICE_BODY,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('PUT', path, {
      token: a.accessToken,
      body: { ...T02_DEVICE_BODY, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const unknown = await h.call('PUT', path, { token: a.accessToken, body: T02_DEVICE_BODY });
    h.expect(unknown.res.status).toBe(404);
    h.expect(h.code(unknown.res)).toBe('DEVICE_NOT_FOUND');
    for (const call of [foreign, injected, unknown]) {
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});

// O03 POS devices (D69). Each shop gets a paired test device (h.pairDevice, the O03 fixture):
// shop A's is the computer its cashier works on, shop B's the one shop A aims at.
const O03_DEVICE_NAME = 'Cross-shop POS';
const o03Name = () => `XS device ${Date.now()}-${Math.random()}`;
/** Shop B's device as its owner sees it in the list. */
async function o03DeviceOfB(h: CrossShopHarness, id: string) {
  const b = await h.login(OWNER_B);
  const list = await h.call('GET', '/api/devices', { token: b.accessToken });
  h.expect(list.res.status, JSON.stringify(list.res.body)).toBe(200);
  return (
    list.res.body as { id: string; name: string; is_active: boolean; paired: boolean }[]
  ).find((device) => device.id === id);
}

crossShopCase({
  method: 'POST',
  path: '/api/devices',
  name: "a device can't be created in shop B: foreign header, org id in the body, B's branch",
  async run(h) {
    const a = await h.login(OWNER_A);
    const body = { branch_id: SHOP_A_BR1, name: o03Name() };
    const foreign = await h.call('POST', '/api/devices', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/devices', {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const branch = await h.call('POST', '/api/devices', {
      token: a.accessToken,
      body: { ...body, branch_id: SHOP_B_BR1 },
    });
    h.expect(branch.res.status).toBe(404);
    h.expect(h.code(branch.res)).toBe('BRANCH_NOT_FOUND');
    for (const call of [foreign, injected, branch]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});

crossShopCase({
  method: 'PATCH',
  path: '/api/devices/:id',
  name: "shop B's device can't be renamed, and shop A's can't be moved to B's branch",
  async run(h) {
    const theirs = await h.pairDevice(SHOP_B, SHOP_B_BR1, O03_DEVICE_NAME);
    const mine = await h.pairDevice(SHOP_A, SHOP_A_BR1, O03_DEVICE_NAME);
    const a = await h.login(OWNER_A);
    const foreign = await h.call('PATCH', `/api/devices/${theirs.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { name: 'Taken over' },
    });
    h.expect(foreign.res.status).toBe(403);
    const rename = await h.call('PATCH', `/api/devices/${theirs.id}`, {
      token: a.accessToken,
      body: { name: 'Taken over' },
    });
    h.expect(rename.res.status).toBe(404);
    h.expect(h.code(rename.res)).toBe('DEVICE_NOT_FOUND');
    const move = await h.call('PATCH', `/api/devices/${mine.id}`, {
      token: a.accessToken,
      body: { branch_id: SHOP_B_BR1 },
    });
    h.expect(move.res.status).toBe(404);
    h.expect(h.code(move.res)).toBe('BRANCH_NOT_FOUND');
    for (const call of [foreign, rename, move]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    h.expect((await o03DeviceOfB(h, theirs.id))?.name).toBe(O03_DEVICE_NAME);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/devices/:id/active',
  name: "shop B's device can't be turned off from shop A",
  async run(h) {
    const theirs = await h.pairDevice(SHOP_B, SHOP_B_BR1, O03_DEVICE_NAME);
    const a = await h.login(OWNER_A);
    const path = `/api/devices/${theirs.id}/active`;
    const body = { active: false, reason: 'cross-shop' };
    const foreign = await h.call('POST', path, { token: a.accessToken, orgId: SHOP_B, body });
    h.expect(foreign.res.status).toBe(403);
    const direct = await h.call('POST', path, { token: a.accessToken, body });
    h.expect(direct.res.status).toBe(404);
    h.expect(h.code(direct.res)).toBe('DEVICE_NOT_FOUND');
    for (const call of [foreign, direct]) {
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    h.expect(await o03DeviceOfB(h, theirs.id)).toMatchObject({ is_active: true, paired: true });
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/devices/:id/pairing-code',
  name: "shop A gets no pairing code for shop B's device",
  async run(h) {
    const theirs = await h.pairDevice(SHOP_B, SHOP_B_BR1, O03_DEVICE_NAME);
    const a = await h.login(OWNER_A);
    const path = `/api/devices/${theirs.id}/pairing-code`;
    const foreign = await h.call('POST', path, { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const direct = await h.call('POST', path, { token: a.accessToken });
    h.expect(direct.res.status).toBe(404);
    h.expect(h.code(direct.res)).toBe('DEVICE_NOT_FOUND');
    for (const call of [foreign, direct]) {
      h.expect(JSON.stringify(call.res.body)).not.toContain('expires_at');
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/devices/:id/unpair',
  name: "shop B's device can't be unpaired from shop A: its computer stays paired",
  async run(h) {
    const theirs = await h.pairDevice(SHOP_B, SHOP_B_BR1, O03_DEVICE_NAME);
    const a = await h.login(OWNER_A);
    const path = `/api/devices/${theirs.id}/unpair`;
    const foreign = await h.call('POST', path, { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const direct = await h.call('POST', path, { token: a.accessToken });
    h.expect(direct.res.status).toBe(404);
    h.expect(h.code(direct.res)).toBe('DEVICE_NOT_FOUND');
    for (const call of [foreign, direct]) {
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    const b = await h.login(OWNER_B);
    const still = await h.call('GET', '/api/devices/current', {
      token: b.accessToken,
      deviceToken: theirs.token,
    });
    h.expect(still.res.status).toBe(200);
    h.expect((still.res.body as { device: { id: string } | null }).device?.id).toBe(theirs.id);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/devices/pair',
  name: 'a pairing code of shop B is an invalid code in shop A, and stays good for shop B',
  async run(h) {
    const theirs = await h.pairDevice(SHOP_B, SHOP_B_BR1, O03_DEVICE_NAME);
    const b = await h.login(OWNER_B);
    const made = await h.call('POST', `/api/devices/${theirs.id}/pairing-code`, {
      token: b.accessToken,
    });
    h.expect(made.res.status, JSON.stringify(made.res.body)).toBe(200);
    const code = (made.res.body as { code: string }).code;

    const a = await h.login(CASHIER_A_EMAIL);
    const foreign = await h.call('POST', '/api/devices/pair', {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { code },
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/devices/pair', {
      token: a.accessToken,
      body: { code, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const typed = await h.call('POST', '/api/devices/pair', {
      token: a.accessToken,
      body: { code },
    });
    h.expect(typed.res.status).toBe(400);
    h.expect(h.code(typed.res)).toBe('PAIRING_CODE_INVALID');
    for (const call of [foreign, injected, typed]) {
      h.expect(JSON.stringify(call.res.body)).not.toContain('device_token');
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    // The code was not used up: shop B's own employee pairs with it.
    const own = await h.call('POST', '/api/devices/pair', { token: b.accessToken, body: { code } });
    h.expect(own.res.status, JSON.stringify(own.res.body)).toBe(200);
    h.expect((own.res.body as { device: { id: string } }).device.id).toBe(theirs.id);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/devices/current',
  name: "shop B's device token is no device in shop A, and a hand-made device id is ignored",
  async run(h) {
    const theirs = await h.pairDevice(SHOP_B, SHOP_B_BR1, O03_DEVICE_NAME);
    const mine = await h.pairDevice(SHOP_A, SHOP_A_BR1, O03_DEVICE_NAME);
    const a = await h.login(CASHIER_A_EMAIL);
    const foreign = await h.call('GET', '/api/devices/current', {
      token: a.accessToken,
      orgId: SHOP_B,
      deviceToken: theirs.token,
    });
    h.expect(foreign.res.status).toBe(403);
    h.expect(h.code(foreign.res)).toBe('SHOP_NOT_ALLOWED');
    const stolen = await h.call('GET', '/api/devices/current', {
      token: a.accessToken,
      deviceToken: theirs.token,
    });
    h.expect(stolen.res.status).toBe(403);
    h.expect(h.code(stolen.res)).toBe('DEVICE_REVOKED');
    const forged = await h.call('GET', '/api/devices/current', {
      token: a.accessToken,
      deviceId: theirs.id,
    });
    h.expect(forged.res.status).toBe(200);
    h.expect(forged.res.body).toEqual({ device: null });
    const own = await h.call('GET', '/api/devices/current', {
      token: a.accessToken,
      deviceToken: mine.token,
    });
    h.expect(own.res.status).toBe(200);
    h.expect(own.res.body).toMatchObject({ device: { id: mine.id, branch_id: SHOP_A_BR1 } });
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/shifts/:id/force-close',
  name: 'force close refuses another shop and leaves its shift unchanged',
  async run(h) {
    const theirs = await openShiftOf(h, OWNER_B, SHOP_B_BR1);
    const a = await h.login(OWNER_A);
    const before = await h.call('GET', `/api/shifts/${theirs.id}`, { token: theirs.token });
    const denied = await h.call('POST', `/api/shifts/${theirs.id}/force-close`, {
      token: a.accessToken,
      body: { counted_cash: '0', reason: 'Lost POS' },
    });
    h.expect(denied.res.status).toBe(404);
    h.expect(h.code(denied.res)).toBe('SHIFT_NOT_FOUND');
    const after = await h.call('GET', `/api/shifts/${theirs.id}`, { token: theirs.token });
    h.expect(after.res.body).toEqual(before.res.body);
    h.expect(await h.auditRowsFrom(SHOP_B, denied.ip)).toBe(0);
    const injected = await h.call('POST', `/api/shifts/${theirs.id}/force-close`, {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { counted_cash: '0', reason: 'Lost POS' },
    });
    h.expect(injected.res.status).toBe(403);
  },
});

// R05 field surveys: shop B's survey (on shop B's customer, assigned to shop B's owner) is made the
// real way, then shop A aims at it. Shop A's own survey goes to shop A's owner.
const OWNER_A_EMPLOYEE_ID = 'd3000000-0000-0000-0000-000000000011';

async function shopBSurvey(h: CrossShopHarness, tag: string) {
  const customer = await shopBCustomer(h, 's-' + tag);
  const created = await h.call('POST', '/api/surveys', {
    token: customer.token,
    body: { customer_id: customer.id, assigned_to: OWNER_B_EMPLOYEE_ID },
  });
  h.expect(created.res.status, JSON.stringify(created.res.body)).toBe(201);
  const survey = created.res.body as { id: string; updated_at: string };
  return { survey, customer, token: customer.token };
}

async function surveyUnchanged(
  h: CrossShopHarness,
  theirs: Awaited<ReturnType<typeof shopBSurvey>>,
) {
  const after = await h.call('GET', `/api/surveys/${theirs.survey.id}`, { token: theirs.token });
  h.expect(after.res.body).toMatchObject({
    status: 'assigned',
    notes: null,
    assigned_to: { id: OWNER_B_EMPLOYEE_ID },
    updated_at: theirs.survey.updated_at,
  });
}

crossShopCase({
  method: 'GET',
  path: '/api/surveys',
  name: "surveys list refuses a foreign header and an org query key, and never shows shop B's",
  async run(h) {
    const theirs = await shopBSurvey(h, 'list');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/surveys', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/surveys', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const byCustomer = await h.call('GET', '/api/surveys', {
      token: a.accessToken,
      query: 'customer_id=' + theirs.customer.id,
    });
    h.expect(byCustomer.res.status).toBe(200);
    h.expect((byCustomer.res.body as { total: number }).total).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});

crossShopCase({
  method: 'GET',
  path: '/api/surveys/:id',
  name: "survey read rejects another shop's id, a foreign header and an org query key",
  async run(h) {
    const theirs = await shopBSurvey(h, 'get');
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', `/api/surveys/${theirs.survey.id}`, {
      token: a.accessToken,
    });
    h.expect(foreign.res.status).toBe(404);
    h.expect(h.code(foreign.res)).toBe('SURVEY_NOT_FOUND');
    const header = await h.call('GET', `/api/surveys/${theirs.survey.id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('GET', `/api/surveys/${theirs.survey.id}`, {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
  },
});

crossShopCase({
  method: 'POST',
  path: '/api/surveys',
  name: "survey assign refuses shop B's customer, shop B's employee, a foreign header and a tenant body",
  async run(h) {
    const theirs = await shopBCustomer(h, 's-assign');
    const mine = await shopACustomer(h, 's-assign');
    const a = await h.login(OWNER_A);
    const customer = await h.call('POST', '/api/surveys', {
      token: a.accessToken,
      body: { customer_id: theirs.id, assigned_to: OWNER_A_EMPLOYEE_ID },
    });
    h.expect(customer.res.status).toBe(404);
    h.expect(h.code(customer.res)).toBe('CUSTOMER_NOT_FOUND');
    const employee = await h.call('POST', '/api/surveys', {
      token: a.accessToken,
      body: { customer_id: mine.id, assigned_to: OWNER_B_EMPLOYEE_ID },
    });
    h.expect(employee.res.status).toBe(409);
    h.expect(h.code(employee.res)).toBe('SURVEY_ASSIGNEE_INVALID');
    const header = await h.call('POST', '/api/surveys', {
      token: a.accessToken,
      orgId: SHOP_B,
      body: { customer_id: theirs.id, assigned_to: OWNER_B_EMPLOYEE_ID },
    });
    h.expect(header.res.status).toBe(403);
    const injected = await h.call('POST', '/api/surveys', {
      token: a.accessToken,
      body: { customer_id: mine.id, assigned_to: OWNER_A_EMPLOYEE_ID, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, customer.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_A, customer.ip)).toBe(0);
    const theirList = await h.call('GET', `/api/customers/${theirs.id}/surveys`, {
      token: theirs.token,
    });
    h.expect(theirList.res.body).toEqual([]);
  },
});

for (const [method, suffix, body] of [
  ['POST', '/reassign', { assigned_to: OWNER_A_EMPLOYEE_ID }],
  ['POST', '/cancel', { reason: 'Foreign cancel' }],
  ['PATCH', '', { notes: 'Foreign' }],
  ['POST', '/submit', {}],
  ['POST', '/decide', { decision: 'approve' }],
] as const) {
  crossShopCase({
    method,
    path: `/api/surveys/:id${suffix}`,
    name: `${method} survey${suffix} rejects another shop's id and leaves it unchanged`,
    async run(h) {
      const theirs = await shopBSurvey(h, method.toLowerCase() + suffix.replace('/', '-'));
      const a = await h.login(OWNER_A);
      const foreign = await h.call(method, `/api/surveys/${theirs.survey.id}${suffix}`, {
        token: a.accessToken,
        body,
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('SURVEY_NOT_FOUND');
      const header = await h.call(method, `/api/surveys/${theirs.survey.id}${suffix}`, {
        token: a.accessToken,
        orgId: SHOP_B,
        body,
      });
      h.expect(header.res.status).toBe(403);
      const injected = await h.call(method, `/api/surveys/${theirs.survey.id}${suffix}`, {
        token: a.accessToken,
        body: { ...body, organization_id: SHOP_B },
      });
      h.expect(injected.res.status).toBe(400);
      h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_A, foreign.ip)).toBe(0);
      await surveyUnchanged(h, theirs);
    },
  });
}

for (const [path, query] of [
  ['surveys', ''],
  ['survey-requirement', 'financed_amount=1000.00'],
] as const) {
  crossShopCase({
    method: 'GET',
    path: `/api/customers/:id/${path}`,
    name: `customer ${path} rejects another shop's customer, a foreign header and an org query key`,
    async run(h) {
      const theirs = await shopBSurvey(h, path);
      const a = await h.login(OWNER_A);
      const foreign = await h.call('GET', `/api/customers/${theirs.customer.id}/${path}`, {
        token: a.accessToken,
        query,
      });
      h.expect(foreign.res.status).toBe(404);
      h.expect(h.code(foreign.res)).toBe('CUSTOMER_NOT_FOUND');
      const header = await h.call('GET', `/api/customers/${theirs.customer.id}/${path}`, {
        token: a.accessToken,
        orgId: SHOP_B,
        query,
      });
      h.expect(header.res.status).toBe(403);
      const injected = await h.call('GET', `/api/customers/${theirs.customer.id}/${path}`, {
        token: a.accessToken,
        query: (query ? query + '&' : '') + 'organization_id=' + SHOP_B,
      });
      h.expect(injected.res.status).toBe(400);
    },
  });
}

// N01: the preview reads only; another shop's customer and guarantors never reach the answer.
crossShopCase({
  method: 'POST',
  path: '/api/installments/sales',
  name: "an installment sale refuses a foreign header, an org id, shop B's customer and guarantor; nothing is written",
  async run(h) {
    const theirs = await shopBGuarantor(h, 'n02-sale');
    const mine = await openShiftOf(h, CASHIER_A_EMAIL, SHOP_A_BR1);
    const body = {
      lines: [{ product_id: '00000000-0000-4000-8000-00000000beef', quantity: 1 }],
      expected_total: '1000.00',
      customer_id: theirs.customer.id,
      terms: {
        down_payment: '100.00',
        installments_count: 2,
        frequency: 'monthly',
        policy_version: 1,
      },
    };
    const send = (sent: object, orgId?: string) =>
      h.call('POST', '/api/installments/sales', {
        token: mine.token,
        deviceToken: mine.deviceToken,
        idempotencyKey: saleKey(),
        body: sent,
        ...(orgId ? { orgId } : {}),
      });
    const foreign = await send(body, SHOP_B);
    h.expect(foreign.res.status).toBe(403);
    const injected = await send({ ...body, organization_id: SHOP_B });
    h.expect(injected.res.status).toBe(400);
    const customer = await send(body);
    h.expect(customer.res.status, JSON.stringify(customer.res.body)).toBe(404);
    h.expect(h.code(customer.res)).toBe('CUSTOMER_NOT_FOUND');
    for (const call of [foreign, injected, customer]) {
      h.expect(await h.auditRowsFrom(SHOP_A, call.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, call.ip)).toBe(0);
    }
    // Nothing was sold: the shift still expects nothing and closes on an empty count.
    await closeShiftOf(h, mine);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/contracts/:id',
  name: 'a contract refuses a foreign header and an unknown or other-shop id',
  async run(h) {
    const a = await h.login(OWNER_A);
    const id = '00000000-0000-4000-8000-00000000c0de';
    const foreign = await h.call('GET', `/api/contracts/${id}`, {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const missing = await h.call('GET', `/api/contracts/${id}`, { token: a.accessToken });
    h.expect(missing.res.status).toBe(404);
    h.expect(h.code(missing.res)).toBe('CONTRACT_NOT_FOUND');
    const injected = await h.call('GET', `/api/contracts/${id}`, {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/installments/preview',
  name: "a preview refuses a foreign header, an org id and shop B's customer; shop B's guarantors are not counted",
  async run(h) {
    await ensureShopAPolicy(h);
    const theirs = await shopBGuarantor(h, 'n01-preview');
    const mine = await shopACustomer(h, 'n01-preview');
    const body = {
      cash_price: '1000.00',
      down_payment: '500.00',
      installments_count: 2,
      frequency: 'monthly',
    };
    const foreign = await h.call('POST', '/api/installments/preview', {
      token: mine.token,
      orgId: SHOP_B,
      body,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/installments/preview', {
      token: mine.token,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const customer = await h.call('POST', '/api/installments/preview', {
      token: mine.token,
      body: { ...body, customer_id: theirs.customer.id },
    });
    h.expect(customer.res.status, JSON.stringify(customer.res.body)).toBe(404);
    h.expect(h.code(customer.res)).toBe('CUSTOMER_NOT_FOUND');
    const guarantors = await h.call('POST', '/api/installments/preview', {
      token: mine.token,
      body: { ...body, customer_id: mine.id, guarantor_ids: [theirs.guarantor.id] },
    });
    h.expect(guarantors.res.status, JSON.stringify(guarantors.res.body)).toBe(200);
    const answer = guarantors.res.body as {
      customer: { guarantors: { selected: number; selected_met: boolean } } | null;
    };
    h.expect(answer.customer?.guarantors.selected).toBe(0);
    h.expect(answer.customer?.guarantors.selected_met).toBe(false);
    h.expect(await h.auditRowsFrom(SHOP_A, foreign.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, foreign.ip)).toBe(0);
  },
});
// N03 (D78). Collections: a foreign shop header is refused, an organization id in the request
// is refused, another shop's (here unknown) contract or receipt is not found, nothing is written.
const N03_UNKNOWN = '00000000-0000-4000-8000-0000000c0113';
crossShopCase({
  method: 'GET',
  path: '/api/contracts',
  name: 'the contract search refuses a foreign header and an org id; shop A sees no other shop',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/contracts', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/contracts', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const mine = await h.call('GET', '/api/contracts', {
      token: a.accessToken,
      query: 'status=all',
    });
    h.expect(mine.res.status, JSON.stringify(mine.res.body)).toBe(200);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/contracts/:id/collection',
  name: 'a collection preview refuses a foreign header, an org id and an unknown or other-shop contract',
  async run(h) {
    const a = await h.login(OWNER_A);
    const path = `/api/contracts/${N03_UNKNOWN}/collection`;
    const foreign = await h.call('GET', path, { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', path, {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const missing = await h.call('GET', path, { token: a.accessToken, query: 'amount=10.00' });
    h.expect(missing.res.status).toBe(404);
    h.expect(h.code(missing.res)).toBe('CONTRACT_NOT_FOUND');
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/collections',
  name: 'a collection refuses a foreign header, an org id and a contract that is not the shop customer’s',
  async run(h) {
    const a = await h.login(OWNER_A);
    const body = {
      customer_id: N03_UNKNOWN,
      contracts: [{ contract_id: N03_UNKNOWN, amount: '1.00' }],
      payments: [{ method: 'cash', amount: '1.00' }],
    };
    const foreign = await h.call('POST', '/api/collections', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
      idempotencyKey: 'n03-xshop-foreign',
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/collections', {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
      idempotencyKey: 'n03-xshop-injected',
    });
    h.expect(injected.res.status).toBe(400);
    // No shift or not its device, or no such customer and contract in shop A: refused either
    // way, nothing written.
    const theirs = await h.call('POST', '/api/collections', {
      token: a.accessToken,
      body,
      idempotencyKey: 'n03-xshop-theirs',
    });
    h.expect([403, 404, 409]).toContain(theirs.res.status);
    h.expect([
      'SHIFT_REQUIRED',
      'DEVICE_REVOKED',
      'DEVICE_MISMATCH',
      'CUSTOMER_NOT_FOUND',
      'CONTRACT_NOT_FOUND',
    ]).toContain(h.code(theirs.res));
    h.expect(await h.auditRowsFrom(SHOP_A, theirs.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, theirs.ip)).toBe(0);
  },
});
for (const [method, suffix] of [
  ['GET', ''],
  ['POST', '/prints'],
] as const) {
  crossShopCase({
    method,
    path: `/api/collections/:id${suffix}`,
    name: `a collection receipt${suffix ? ' print' : ''} refuses a foreign header, an org id and an unknown or other-shop id`,
    async run(h) {
      const a = await h.login(OWNER_A);
      const path = `/api/collections/${N03_UNKNOWN}${suffix}`;
      const foreign = await h.call(method, path, { token: a.accessToken, orgId: SHOP_B });
      h.expect(foreign.res.status).toBe(403);
      const injected = await h.call(method, path, {
        token: a.accessToken,
        query: 'organization_id=' + SHOP_B,
      });
      h.expect(injected.res.status).toBe(400);
      const missing = await h.call(method, path, { token: a.accessToken });
      h.expect(missing.res.status).toBe(404);
      h.expect(h.code(missing.res)).toBe('COLLECTION_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_A, missing.ip)).toBe(0);
    },
  });
}
crossShopCase({
  method: 'POST',
  path: '/api/collections/:id/reverse',
  name: 'a reversal refuses a foreign header, an org id and an unknown or other-shop receipt',
  async run(h) {
    const a = await h.login(OWNER_A);
    const path = `/api/collections/${N03_UNKNOWN}/reverse`;
    const body = { reason: 'Cross-shop check' };
    const foreign = await h.call('POST', path, {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
      idempotencyKey: 'n03-xshop-rev-foreign',
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', path, {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
      idempotencyKey: 'n03-xshop-rev-injected',
    });
    h.expect(injected.res.status).toBe(400);
    const missing = await h.call('POST', path, {
      token: a.accessToken,
      body,
      idempotencyKey: 'n03-xshop-rev-missing',
    });
    h.expect(missing.res.status).toBe(404);
    h.expect(h.code(missing.res)).toBe('COLLECTION_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_A, missing.ip)).toBe(0);
  },
});

// N04 (D79). Overdue tracking: a foreign shop header is refused, an organization id in the request
// is refused, another shop's (here unknown) warning or referral is not found, nothing is written.
const N04_UNKNOWN = '00000000-0000-4000-8000-0000000c0114';
for (const path of [
  '/api/overdue',
  '/api/overdue/warnings',
  '/api/overdue/legal-referrals',
] as const) {
  crossShopCase({
    method: 'GET',
    path,
    name: `${path} refuses a foreign header and an org id; shop A reads only its own`,
    async run(h) {
      const a = await h.login(OWNER_A);
      const foreign = await h.call('GET', path, { token: a.accessToken, orgId: SHOP_B });
      h.expect(foreign.res.status).toBe(403);
      const injected = await h.call('GET', path, {
        token: a.accessToken,
        query: 'organization_id=' + SHOP_B,
      });
      h.expect(injected.res.status).toBe(400);
      const mine = await h.call('GET', path, { token: a.accessToken });
      h.expect(mine.res.status, JSON.stringify(mine.res.body)).toBe(200);
    },
  });
}
for (const [suffix, body, code] of [
  ['/api/overdue/warnings/:id/handle', { outcome: 'contacted' }, 'handle'],
  ['/api/overdue/legal-referrals/:id/dismiss', { reason: 'Cross-shop check' }, 'dismiss'],
] as const) {
  crossShopCase({
    method: 'POST',
    path: suffix,
    name: `${code}: refuses a foreign header, an org id and an unknown or other-shop id`,
    async run(h) {
      const a = await h.login(OWNER_A);
      const path = suffix.replace(':id', N04_UNKNOWN);
      const foreign = await h.call('POST', path, { token: a.accessToken, orgId: SHOP_B, body });
      h.expect(foreign.res.status).toBe(403);
      const injected = await h.call('POST', path, {
        token: a.accessToken,
        body: { ...body, organization_id: SHOP_B },
      });
      h.expect(injected.res.status).toBe(400);
      const missing = await h.call('POST', path, { token: a.accessToken, body });
      h.expect(missing.res.status).toBe(404);
      h.expect(h.code(missing.res)).toBe('OVERDUE_ACTION_NOT_FOUND');
      h.expect(await h.auditRowsFrom(SHOP_A, missing.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, missing.ip)).toBe(0);
    },
  });
}
crossShopCase({
  method: 'POST',
  path: '/api/overdue/run',
  name: 'the manual overdue check refuses a foreign header and an org id; it only checks the caller’s shop',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('POST', '/api/overdue/run', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/overdue/run', {
      token: a.accessToken,
      body: { organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    h.expect(await h.auditRowsFrom(SHOP_B, injected.ip)).toBe(0);
  },
});

// N05 (D80). Contract changes: a foreign shop header is refused, an organization id in the request
// is refused, another shop's (here unknown) contract is not found, nothing is written.
const N05_UNKNOWN = '00000000-0000-4000-8000-0000000c0115';
for (const suffix of ['/settlement-quote', '/changes'] as const) {
  crossShopCase({
    method: 'GET',
    path: `/api/contracts/:id${suffix}`,
    name: `${suffix}: refuses a foreign header, an org id and an unknown or other-shop contract`,
    async run(h) {
      const a = await h.login(OWNER_A);
      const path = `/api/contracts/${N05_UNKNOWN}${suffix}`;
      const foreign = await h.call('GET', path, { token: a.accessToken, orgId: SHOP_B });
      h.expect(foreign.res.status).toBe(403);
      const injected = await h.call('GET', path, {
        token: a.accessToken,
        query: 'organization_id=' + SHOP_B,
      });
      h.expect(injected.res.status).toBe(400);
      const missing = await h.call('GET', path, { token: a.accessToken });
      h.expect(missing.res.status).toBe(404);
      h.expect(h.code(missing.res)).toBe('CONTRACT_NOT_FOUND');
    },
  });
}
const n05Plan = { installments_count: 3, frequency: 'monthly', first_due_date: '2030-01-15' };
for (const [suffix, body, keyed] of [
  [
    '/settle',
    {
      waiver: '0.00',
      expected_remaining: '1.00',
      payments: [{ method: 'cash', amount: '1.00' }],
    },
    true,
  ],
  ['/reschedule/preview', n05Plan, false],
  ['/reschedule', { ...n05Plan, reason: 'Cross-shop check', expected_remaining: '1.00' }, true],
  ['/write-off', { reason: 'Cross-shop check', expected_remaining: '1.00' }, true],
] as const) {
  crossShopCase({
    method: 'POST',
    path: `/api/contracts/:id${suffix}`,
    name: `${suffix}: refuses a foreign header, an org id and an unknown or other-shop contract`,
    async run(h) {
      const a = await h.login(OWNER_A);
      const path = `/api/contracts/${N05_UNKNOWN}${suffix}`;
      const key = (tag: string) => (keyed ? { idempotencyKey: `n05-xshop${suffix}-${tag}` } : {});
      const foreign = await h.call('POST', path, {
        token: a.accessToken,
        orgId: SHOP_B,
        body,
        ...key('foreign'),
      });
      h.expect(foreign.res.status).toBe(403);
      const injected = await h.call('POST', path, {
        token: a.accessToken,
        body: { ...body, organization_id: SHOP_B },
        ...key('injected'),
      });
      h.expect(injected.res.status).toBe(400);
      // The settlement needs the caller's open shift first: refused either way, nothing written.
      const missing = await h.call('POST', path, { token: a.accessToken, body, ...key('missing') });
      h.expect([403, 404, 409]).toContain(missing.res.status);
      h.expect(
        suffix === '/settle'
          ? ['SHIFT_REQUIRED', 'DEVICE_REVOKED', 'DEVICE_MISMATCH', 'CONTRACT_NOT_FOUND']
          : ['CONTRACT_NOT_FOUND'],
      ).toContain(h.code(missing.res));
      h.expect(await h.auditRowsFrom(SHOP_A, missing.ip)).toBe(0);
      h.expect(await h.auditRowsFrom(SHOP_B, missing.ip)).toBe(0);
    },
  });
}
crossShopCase({
  method: 'GET',
  path: '/api/contract-changes',
  name: 'the contract change list refuses a foreign header and an org id; shop A reads only its own',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/contract-changes', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/contract-changes', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const mine = await h.call('GET', '/api/contract-changes', { token: a.accessToken });
    h.expect(mine.res.status, JSON.stringify(mine.res.body)).toBe(200);
  },
});

// N06 (D81). Collector wallets: a foreign shop header is refused, an organization id in the request
// is refused, another shop's (here unknown) wallet, customer or employee is not found, nothing is
// written.
const N06_UNKNOWN = '00000000-0000-4000-8000-0000000c0116';
crossShopCase({
  method: 'GET',
  path: '/api/wallets/me',
  name: 'my wallet refuses a foreign header; shop A reads only its own',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/wallets/me', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const mine = await h.call('GET', '/api/wallets/me', { token: a.accessToken });
    h.expect(mine.res.status, JSON.stringify(mine.res.body)).toBe(200);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/wallets',
  name: 'the wallet list refuses a foreign header and an org id; shop A reads only its own',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/wallets', { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/wallets', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const mine = await h.call('GET', '/api/wallets', { token: a.accessToken });
    h.expect(mine.res.status, JSON.stringify(mine.res.body)).toBe(200);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/wallets/:id/movements',
  name: 'a wallet ledger refuses a foreign header, an org id and an unknown or other-shop wallet',
  async run(h) {
    const a = await h.login(OWNER_A);
    const path = `/api/wallets/${N06_UNKNOWN}/movements`;
    const foreign = await h.call('GET', path, { token: a.accessToken, orgId: SHOP_B });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', path, {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const missing = await h.call('GET', path, { token: a.accessToken });
    h.expect(missing.res.status).toBe(404);
    h.expect(h.code(missing.res)).toBe('WALLET_NOT_FOUND');
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/wallets/:id/settle',
  name: 'settling refuses a foreign header, an org id and an unknown or other-shop wallet',
  async run(h) {
    const a = await h.login(OWNER_A);
    const path = `/api/wallets/${N06_UNKNOWN}/settle`;
    const body = { to_account_id: N06_UNKNOWN, handed: '1.00', expected_balance: '1.00' };
    const foreign = await h.call('POST', path, {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
      idempotencyKey: 'n06-xshop-settle-foreign',
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', path, {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
      idempotencyKey: 'n06-xshop-settle-injected',
    });
    h.expect(injected.res.status).toBe(400);
    const missing = await h.call('POST', path, {
      token: a.accessToken,
      body,
      idempotencyKey: 'n06-xshop-settle-missing',
    });
    h.expect(missing.res.status).toBe(404);
    h.expect(h.code(missing.res)).toBe('WALLET_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_A, missing.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, missing.ip)).toBe(0);
  },
});
crossShopCase({
  method: 'PUT',
  path: '/api/customers/:id/collector',
  name: 'assigning a collector refuses a foreign header, an org id and an unknown or other-shop customer',
  async run(h) {
    const a = await h.login(OWNER_A);
    const path = `/api/customers/${N06_UNKNOWN}/collector`;
    const body = { employee_id: null };
    const foreign = await h.call('PUT', path, { token: a.accessToken, orgId: SHOP_B, body });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('PUT', path, {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
    });
    h.expect(injected.res.status).toBe(400);
    const missing = await h.call('PUT', path, { token: a.accessToken, body });
    h.expect(missing.res.status).toBe(404);
    h.expect(h.code(missing.res)).toBe('CUSTOMER_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_A, missing.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, missing.ip)).toBe(0);
  },
});
crossShopCase({
  method: 'GET',
  path: '/api/collectors/route',
  name: 'the route refuses a foreign header and an org id; an unknown employee is not found',
  async run(h) {
    const a = await h.login(OWNER_A);
    const foreign = await h.call('GET', '/api/collectors/route', {
      token: a.accessToken,
      orgId: SHOP_B,
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('GET', '/api/collectors/route', {
      token: a.accessToken,
      query: 'organization_id=' + SHOP_B,
    });
    h.expect(injected.res.status).toBe(400);
    const missing = await h.call('GET', '/api/collectors/route', {
      token: a.accessToken,
      query: 'employee_id=' + N06_UNKNOWN,
    });
    h.expect(missing.res.status).toBe(404);
    h.expect(h.code(missing.res)).toBe('EMPLOYEE_NOT_FOUND');
  },
});
crossShopCase({
  method: 'POST',
  path: '/api/collections/field',
  name: 'a field collection refuses a foreign header, an org id and an unknown or other-shop customer',
  async run(h) {
    const a = await h.login(OWNER_A);
    const body = {
      customer_id: N06_UNKNOWN,
      contracts: [{ contract_id: N06_UNKNOWN, amount: '1.00' }],
      payments: [{ method: 'cash', amount: '1.00' }],
    };
    const foreign = await h.call('POST', '/api/collections/field', {
      token: a.accessToken,
      orgId: SHOP_B,
      body,
      idempotencyKey: 'n06-xshop-field-foreign',
    });
    h.expect(foreign.res.status).toBe(403);
    const injected = await h.call('POST', '/api/collections/field', {
      token: a.accessToken,
      body: { ...body, organization_id: SHOP_B },
      idempotencyKey: 'n06-xshop-field-injected',
    });
    h.expect(injected.res.status).toBe(400);
    const missing = await h.call('POST', '/api/collections/field', {
      token: a.accessToken,
      body,
      idempotencyKey: 'n06-xshop-field-missing',
    });
    h.expect(missing.res.status).toBe(404);
    h.expect(h.code(missing.res)).toBe('CUSTOMER_NOT_FOUND');
    h.expect(await h.auditRowsFrom(SHOP_A, missing.ip)).toBe(0);
    h.expect(await h.auditRowsFrom(SHOP_B, missing.ip)).toBe(0);
  },
});
