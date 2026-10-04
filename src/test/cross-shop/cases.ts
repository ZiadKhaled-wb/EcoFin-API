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
