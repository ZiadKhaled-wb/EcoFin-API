// src/test/cross-shop/cases.ts
//
// One or more cross-shop cases per non-public route (D19, F05). A new route without a case here
// fails `npm run check:cross-shop` and `npm test` (check.test.ts).
//
// Pattern: log in as a user of shop A, aim the request at shop B (x-org-id, a body id, a path
// id), expect 403/404, then prove shop B didn't change (no audit row from this call's IP, B's
// session still works, A's password unchanged...).

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
