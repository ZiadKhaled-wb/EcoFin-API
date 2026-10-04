// src/test/route-access/check.ts
//
// F06 / D19: every route the app serves carries exactly one access marker
// (publicRoute(), authenticatedOnly() or requirePermission(key)). `npm run check:permissions`
// (scripts/check-permissions.ts) and check.test.ts run this, so a route without one fails CI.

import type { Application } from 'express';
import { routeAccessOf, type RouteAccess } from '../../middleware/permissions';
import { listRoutes, routeKey, type RouteInfo } from '../../routes/registry';

export interface RouteAccessEntry {
  route: string;
  access: RouteAccess;
}

export interface RouteAccessReport {
  /** Every correctly marked route with its marker, for the log. */
  marked: RouteAccessEntry[];
  /** Routes with no marker. */
  missing: string[];
  /** Routes with more than one marker (ambiguous: which one is meant?). */
  several: string[];
}

export function checkRouteAccess(routes: readonly RouteInfo[]): RouteAccessReport {
  const report: RouteAccessReport = { marked: [], missing: [], several: [] };
  for (const route of routes) {
    const markers = route.handlers
      .map(routeAccessOf)
      .filter((a): a is RouteAccess => a !== undefined);
    const [only] = markers;
    if (markers.length === 0 || only === undefined) report.missing.push(routeKey(route));
    else if (markers.length > 1) report.several.push(routeKey(route));
    else report.marked.push({ route: routeKey(route), access: only });
  }
  return report;
}

const describeAccess = (a: RouteAccess): string =>
  a.kind === 'permission' ? `permission ${a.key}` : a.kind;

/** The CI check: 0 when every route has exactly one marker, 1 (routes named) otherwise. */
export function runRouteAccessCheck(app: Application, log: (line: string) => void): 0 | 1 {
  const { marked, missing, several } = checkRouteAccess(listRoutes(app));
  for (const key of missing) {
    log(
      `MISSING access marker: ${key} (add requirePermission(key), authenticatedOnly() or publicRoute())`,
    );
  }
  for (const key of several) log(`SEVERAL access markers: ${key} (keep exactly one)`);
  if (missing.length > 0 || several.length > 0) return 1;
  for (const { route, access } of marked) log(`  ${route}: ${describeAccess(access)}`);
  log(`permission check: ${marked.length} routes, all marked.`);
  return 0;
}
