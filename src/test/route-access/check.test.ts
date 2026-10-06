// The same check as `npm run check:permissions`, so `npm test` also fails on an unmarked route.
import { describe, it, expect } from 'vitest';
import { Router } from 'express';
import { createApp } from '../../app';
import { publicRoute, requirePermission } from '../../middleware/permissions';
import { listRoutes, mountRouter } from '../../routes/registry';
import { checkRouteAccess, runRouteAccessCheck } from './check';

const env = { TRUST_PROXY: false as const, CORS_ALLOWED_ORIGINS: [] as string[] };

describe('route access check (F06 / D19)', () => {
  it('the current app: every route has exactly one marker', () => {
    const lines: string[] = [];
    const code = runRouteAccessCheck(createApp({ env }), (l) => lines.push(l));
    expect(lines.join('\n')).not.toMatch(/MISSING|SEVERAL/);
    expect(code).toBe(0);
  });

  it('the markers are the intended ones', () => {
    const { marked } = checkRouteAccess(listRoutes(createApp({ env })));
    const byRoute = Object.fromEntries(marked.map((m) => [m.route, m.access]));
    expect(byRoute['GET /health']).toEqual({ kind: 'public' });
    expect(byRoute['POST /api/auth/login']).toEqual({ kind: 'public' });
    expect(byRoute['GET /api/auth/me']).toEqual({ kind: 'authenticated' });
    expect(byRoute['GET /api/me/permissions']).toEqual({ kind: 'authenticated' });
    expect(byRoute['PUT /api/employees/:employeeId/permissions']).toEqual({
      kind: 'permission',
      key: 'employee.manage',
    });
    expect(byRoute['PUT /api/employees/:employeeId/branches']).toEqual({
      kind: 'permission',
      key: 'employee.manage',
    });
    // EC-143
    expect(byRoute['PUT /api/employees/:employeeId/active']).toEqual({
      kind: 'permission',
      key: 'employee.manage',
    });
    // F14: the permission depends on the file's purpose, so the service checks it per request.
    expect(byRoute['POST /api/files']).toEqual({ kind: 'authenticated' });
    expect(byRoute['GET /api/files']).toEqual({ kind: 'authenticated' });
    expect(byRoute['GET /api/files/:id/url']).toEqual({ kind: 'authenticated' });
  });

  it('a new route without a marker fails (exit 1) and is named', () => {
    const app = createApp({ env });
    const extra = Router();
    extra.post('/', (_req, res) => {
      res.json({});
    });
    mountRouter(app, '/api/products', extra);
    const lines: string[] = [];
    expect(runRouteAccessCheck(app, (l) => lines.push(l))).toBe(1);
    expect(lines.some((l) => l.startsWith('MISSING access marker: POST /api/products'))).toBe(true);
  });

  it('a route with two markers fails', () => {
    const app = createApp({ env });
    const extra = Router();
    extra.get('/', publicRoute(), requirePermission('sale.create'), (_req, res) => {
      res.json({});
    });
    mountRouter(app, '/api/odd', extra);
    const lines: string[] = [];
    expect(runRouteAccessCheck(app, (l) => lines.push(l))).toBe(1);
    expect(lines).toContain('SEVERAL access markers: GET /api/odd (keep exactly one)');
  });
});
