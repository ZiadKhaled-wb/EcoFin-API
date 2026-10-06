// src/test/cross-shop/cases.ts
//
// One or more cross-shop cases per non-public route (D19, F05). A new route without a case here
// fails `npm run check:cross-shop` and `npm test` (check.test.ts).
//
// Pattern: log in as a user of shop A, aim the request at shop B (x-org-id, a body id, a path
// id), expect 403/404, then prove shop B didn't change (no audit row from this call's IP, B's
// session still works, A's password unchanged...).

import { crossShopCase, SHOP_A, SHOP_B } from './harness';

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
