// src/test/audit-registry/check.ts
//
// The CI check behind `npm run check:audit` (scripts/check-audit.ts) and check.test.ts.

import type { Application } from 'express';
import { listRoutes, routeKey, type RouteInfo } from '../../routes/registry';
import { AUDIT_REGISTRY, type AuditExpectation } from './registry';

export interface AuditRegistryReport {
  /** Write routes the app serves with no registry entry. */
  missing: string[];
  /** Registry entries for routes the app doesn't serve (renamed or removed). */
  stale: string[];
  /** Entries that are neither an action nor a reasoned `none`. */
  invalid: string[];
}

const isWrite = (r: Pick<RouteInfo, 'method'>) => r.method !== 'GET' && r.method !== 'HEAD';

function valid(e: AuditExpectation): boolean {
  if ('action' in e) return /^[a-z_]+(\.[a-z_]+)+$/.test(e.action);
  return e.none.trim().length >= 10;
}

export function checkAuditRegistry(
  routes: readonly Pick<RouteInfo, 'method' | 'path'>[],
  registry: Readonly<Record<string, AuditExpectation>> = AUDIT_REGISTRY,
): AuditRegistryReport {
  const writes = new Set(routes.filter(isWrite).map(routeKey));
  return {
    missing: [...writes].filter((k) => !(k in registry)),
    stale: Object.keys(registry).filter((k) => !writes.has(k)),
    invalid: Object.entries(registry)
      .filter(([, e]) => !valid(e))
      .map(([k]) => k),
  };
}

export function runAuditRegistryCheck(app: Application, log: (line: string) => void): 0 | 1 {
  const { missing, stale, invalid } = checkAuditRegistry(listRoutes(app));
  for (const k of missing) {
    log(`MISSING audit entry: ${k} (add it to src/test/audit-registry/registry.ts)`);
  }
  for (const k of stale) log(`STALE audit entry: ${k} is not a write route of the app`);
  for (const k of invalid)
    log(`INVALID audit entry: ${k} (an action like 'sale.create' or a reason)`);
  if (missing.length + stale.length + invalid.length > 0) return 1;
  log(`audit check: ${Object.keys(AUDIT_REGISTRY).length} write routes, all registered.`);
  return 0;
}
