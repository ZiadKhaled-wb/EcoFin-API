// src/test/cross-shop/harness.ts
//
// F05 cross-shop suite (D19). Every non-public route registers at least one crossShopCase: a user
// of shop A tries to read or change shop B's data through that route and must get 403/404 with no
// change in shop B. The cases run against local Supabase under RUN_INTEGRATION=1
// (cross-shop.integration.test.ts); `npm run check:cross-shop` and check.test.ts fail when a
// route has no case and isn't in PUBLIC_ROUTES.
//
// No vitest import here: scripts/check-cross-shop.ts loads the cases outside the test runner, so
// `expect` reaches a case through the harness.

import type { ExpectStatic } from 'vitest';
import type { Response } from 'supertest';
import type { Application } from 'express';
import { listRoutes, routeKey, type RouteInfo } from '../../routes/registry';

/** Seeded shops (supabase/seeds/02_dev_data.sql). A is the caller's shop, B the target. */
export const SHOP_A = 'd1000000-0000-0000-0000-000000000001';
export const SHOP_B = 'd1000000-0000-0000-0000-000000000002';

/** Routes nobody needs a session for, so there is no shop to cross. Keyed `METHOD /path`. */
export const PUBLIC_ROUTES: readonly string[] = [
  'POST /api/auth/password-reset/lookup',
  'POST /api/auth/password-reset/complete',
  'GET /health',
  'POST /api/auth/login',
  'POST /api/auth/refresh',
  'POST /api/auth/forgot-password',
  'POST /api/auth/reset-password',
  'POST /api/auth/invites/lookup',
  'POST /api/auth/invites/accept',
  // Platform level, no shop context. P01 covers super-admin-only access and caller JWTs.
  'GET /api/admin/plans',
  'GET /api/admin/shops',
  'POST /api/admin/shops',
  'POST /api/admin/shops/:id/status',
  'POST /api/admin/shops/:id/owner-invite',
  // P05 platform level, no shop context; tested with non-admin callers.
  'GET /api/admin/shops/:id/subscription',
  'POST /api/admin/shops/:id/plan',
  'POST /api/admin/shops/:id/subscription-dates',
  'POST /api/admin/shops/:id/payments',
];

export interface CallOptions {
  token?: string;
  /** Sent as the x-org-id header. */
  orgId?: string;
  body?: object;
  /** Raw query string without '?', e.g. `orgId=...`. */
  query?: string;
  /** Sent as the Idempotency-Key header (stock and money writes). */
  idempotencyKey?: string;
}

export interface CrossShopHarness {
  expect: ExpectStatic;
  /** Logs in with the seed password; fails the case unless the login succeeds. */
  login(
    identifier: string,
    tenantSlug?: string,
  ): Promise<{ accessToken: string; refreshToken: string }>;
  /** Calls the app from a fresh client IP; the IP is returned so audit rows can be traced. */
  call(method: string, path: string, options?: CallOptions): Promise<{ res: Response; ip: string }>;
  /** error.code of a contract error response. */
  code(res: Response): string;
  /** audit_log rows in `orgId` written from `ip` since its latest call (service-role read, test only). */
  auditRowsFrom(orgId: string, ip: string): Promise<number>;
  /** An employee's permission overrides, branch ids and active flag (service-role read, test only). */
  accessOf(
    employeeId: string,
  ): Promise<{ overrides: string[]; branchIds: string[]; active: boolean }>;
}

export interface CrossShopCase {
  method: string;
  /** As mounted, e.g. /api/auth/me (a route pattern like /api/products/:id for routes with params). */
  path: string;
  name: string;
  run(h: CrossShopHarness): Promise<void>;
}

const cases: CrossShopCase[] = [];

export function crossShopCase(c: CrossShopCase): void {
  cases.push({ ...c, method: c.method.toUpperCase() });
}

export function registeredCases(): readonly CrossShopCase[] {
  return cases;
}

export interface CrossShopReport {
  /** Routes with neither a case nor a PUBLIC_ROUTES entry. */
  uncovered: string[];
  /** Cases (or public entries) for a route the app doesn't serve: stale, probably renamed. */
  stale: string[];
}

export function checkCrossShop(
  routes: readonly Pick<RouteInfo, 'method' | 'path'>[],
  caseList: readonly Pick<CrossShopCase, 'method' | 'path'>[],
  publicRoutes: readonly string[] = PUBLIC_ROUTES,
): CrossShopReport {
  const served = new Set(routes.map(routeKey));
  const covered = new Set([...caseList.map(routeKey), ...publicRoutes]);
  return {
    uncovered: [...served].filter((key) => !covered.has(key)),
    stale: [...covered].filter((key) => !served.has(key)),
  };
}

/** The CI check: 0 when every route is covered, 1 (with the routes named) otherwise. */
export function runCrossShopCheck(
  app: Application,
  caseList: readonly Pick<CrossShopCase, 'method' | 'path'>[],
  log: (line: string) => void,
): 0 | 1 {
  const routes = listRoutes(app);
  const { uncovered, stale } = checkCrossShop(routes, caseList);
  for (const key of uncovered) {
    log(`MISSING cross-shop case: ${key} (add one in src/test/cross-shop/cases.ts)`);
  }
  for (const key of stale) {
    log(`STALE cross-shop entry: ${key} is not served by the app`);
  }
  if (uncovered.length > 0 || stale.length > 0) return 1;
  log(`cross-shop check: ${routes.length} routes, all covered.`);
  return 0;
}
