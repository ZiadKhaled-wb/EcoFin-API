// server/src/routes/registry.ts
//
// D19: every route must carry its checks (F05 a cross-shop case, F06 a permission marker, F07 an
// audit entry), and CI fails when one is missing. That needs the full list of routes the app
// really serves, so routers are mounted through mountRouter(), which remembers each prefix, and
// listRoutes(app) walks Express's own stack. A router mounted with plain app.use() can't be
// listed, so listRoutes refuses it rather than silently skipping its routes.

import type { Application, Router } from 'express';

export interface RouteInfo {
  /** Upper-case HTTP method, e.g. GET. */
  method: string;
  /** Full path as mounted, e.g. /api/auth/me. */
  path: string;
}

const prefixes = new WeakMap<Application, Map<unknown, string>>();

/** app.use(prefix, router), remembered for listRoutes(). */
export function mountRouter(app: Application, prefix: string, router: Router): void {
  app.use(prefix, router);
  let mounted = prefixes.get(app);
  if (!mounted) {
    mounted = new Map();
    prefixes.set(app, mounted);
  }
  mounted.set(router, prefix);
}

// The parts of Express 4's Layer this module reads. Express doesn't export these types.
interface Layer {
  name: string;
  handle: unknown;
  route?: { path: unknown; methods: Record<string, boolean | undefined> };
}

function stackOf(holder: unknown): Layer[] {
  const stack = (holder as { stack?: unknown } | undefined)?.stack;
  return Array.isArray(stack) ? (stack as Layer[]) : [];
}

function join(prefix: string, path: string): string {
  if (path === '/' || path === '') return prefix === '' ? '/' : prefix;
  return `${prefix}${path}`;
}

function routesOf(layer: Layer, prefix: string, where: string): RouteInfo[] {
  if (!layer.route) return [];
  const { path, methods } = layer.route;
  if (typeof path !== 'string') {
    throw new Error(`listRoutes: ${where} has a non-string route path; use a string path.`);
  }
  return Object.keys(methods)
    .filter((m) => methods[m])
    .map((m) => ({ method: m === '_all' ? 'ALL' : m.toUpperCase(), path: join(prefix, path) }));
}

/** Every route the app serves, sorted by path then method. */
export function listRoutes(app: Application): RouteInfo[] {
  const mounted = prefixes.get(app) ?? new Map<unknown, string>();
  const out: RouteInfo[] = [];
  for (const layer of stackOf((app as unknown as { _router?: unknown })._router)) {
    if (layer.route) {
      out.push(...routesOf(layer, '', 'the app'));
      continue;
    }
    if (layer.name !== 'router') continue; // plain middleware (json, cors, 404, ...)
    const prefix = mounted.get(layer.handle);
    if (prefix === undefined) {
      throw new Error(
        'listRoutes: a router was mounted without mountRouter(); its routes are invisible.',
      );
    }
    for (const inner of stackOf(layer.handle)) {
      if (inner.name === 'router') {
        throw new Error(`listRoutes: nested routers under ${prefix} are not supported.`);
      }
      out.push(...routesOf(inner, prefix, prefix));
    }
  }
  return out.sort((a, b) => a.path.localeCompare(b.path) || a.method.localeCompare(b.method));
}

/** `GET /api/auth/me`: the key used by route registries (cross-shop cases, F06, F07). */
export const routeKey = (route: RouteInfo): string => `${route.method} ${route.path}`;
