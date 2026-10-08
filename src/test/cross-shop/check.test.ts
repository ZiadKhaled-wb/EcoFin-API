// The same check as `npm run check:cross-shop`, so `npm test` also fails on an uncovered route.
import { describe, it, expect } from 'vitest';
import { Router } from 'express';
import { createApp } from '../../app';
import { listRoutes, mountRouter } from '../../routes/registry';
import { checkCrossShop, registeredCases, runCrossShopCheck, PUBLIC_ROUTES } from './harness';
import './cases';

const env = { TRUST_PROXY: false as const, CORS_ALLOWED_ORIGINS: [] as string[] };

describe('cross-shop route check (D19)', () => {
  it('the current app: every route has a cross-shop case or is public', () => {
    const lines: string[] = [];
    const code = runCrossShopCheck(createApp({ env }), registeredCases(), (l) => lines.push(l));
    expect(lines.join('\n')).not.toMatch(/MISSING|STALE/);
    expect(code).toBe(0);
  });

  it('lists the routes the app really serves', () => {
    const keys = listRoutes(createApp({ env })).map((r) => `${r.method} ${r.path}`);
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /health',
        'GET /api/auth/me',
        'POST /api/auth/login',
        'POST /api/auth/select-shop',
        'POST /api/auth/invites/lookup',
        'POST /api/auth/invites/accept',
        'GET /api/admin/plans',
        'GET /api/admin/shops',
        'POST /api/admin/shops',
        'POST /api/admin/shops/:id/status',
        'POST /api/admin/shops/:id/owner-invite',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /api/subscription',
        'GET /api/admin/shops/:id/subscription',
        'POST /api/admin/shops/:id/plan',
        'POST /api/admin/shops/:id/subscription-dates',
        'POST /api/admin/shops/:id/payments',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /api/branches',
        'GET /api/branches/manage',
        'GET /api/branches/:id',
        'POST /api/branches',
        'PATCH /api/branches/:id',
        'GET /api/branches/:id/deactivation-check',
        'POST /api/branches/:id/deactivate',
        'POST /api/branches/:id/reactivate',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /api/settings',
        'PATCH /api/settings',
        'GET /api/settings/installment-policies',
        'POST /api/settings/installment-policies',
        'GET /api/tax-classes',
        'POST /api/tax-classes',
        'PATCH /api/tax-classes/:id',
        'POST /api/tax-classes/:id/archive',
        'POST /api/tax-classes/:id/restore',
        'GET /api/categories',
        'POST /api/categories',
        'PATCH /api/categories/:id',
        'POST /api/categories/:id/archive',
        'POST /api/categories/:id/restore',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining(['GET /api/settings/profile', 'PATCH /api/settings/profile']),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /api/products',
        'GET /api/products/lookup',
        'GET /api/products/:id',
        'POST /api/products',
        'PATCH /api/products/:id',
        'POST /api/products/:id/archive',
        'POST /api/products/:id/restore',
        'GET /api/products/:id/units',
        'GET /api/stock',
        'GET /api/stock/movements',
        'GET /api/stock/adjustments',
        'GET /api/stock/adjustments/:id',
        'POST /api/stock/adjustments',
        'GET /api/stock/counts',
        'POST /api/stock/counts',
        'GET /api/stock/counts/:id',
        'PUT /api/stock/counts/:id/lines',
        'POST /api/stock/counts/:id/scan',
        'POST /api/stock/counts/:id/post',
        'POST /api/stock/counts/:id/cancel',
        'GET /api/stock/transfers',
        'POST /api/stock/transfers',
        'GET /api/stock/transfers/:id',
        'PUT /api/stock/transfers/:id',
        'POST /api/stock/transfers/:id/send',
        'POST /api/stock/transfers/:id/receive',
        'POST /api/stock/transfers/:id/cancel',
        'GET /api/stock/transfers/destinations',
      ]),
    );
    expect(keys).toHaveLength(89);
  });

  it('a new route without a case fails (exit 1) and is named', () => {
    const app = createApp({ env });
    const extra = Router();
    extra.get('/:id', (_req, res) => {
      res.json({});
    });
    mountRouter(app, '/api/widgets', extra);
    const lines: string[] = [];
    expect(runCrossShopCheck(app, registeredCases(), (l) => lines.push(l))).toBe(1);
    expect(lines).toContain(
      'MISSING cross-shop case: GET /api/widgets/:id (add one in src/test/cross-shop/cases.ts)',
    );
  });

  it('a route added straight on the app is seen too', () => {
    const app = createApp({ env });
    app.post('/api/sneaky', (_req, res) => {
      res.json({});
    });
    const lines: string[] = [];
    expect(runCrossShopCheck(app, registeredCases(), (l) => lines.push(l))).toBe(1);
    expect(lines.some((l) => l.includes('POST /api/sneaky'))).toBe(true);
  });

  it('a router mounted without mountRouter() makes the check fail loudly', () => {
    const app = createApp({ env });
    app.use(
      '/api/hidden',
      Router().get('/', (_req, res) => res.json({})),
    );
    expect(() => listRoutes(app)).toThrow(/without mountRouter/);
  });

  it('a case for a route that no longer exists is reported as stale', () => {
    const report = checkCrossShop(
      [{ method: 'GET', path: '/api/auth/me' }],
      [
        { method: 'GET', path: '/api/auth/me' },
        { method: 'GET', path: '/api/auth/old' },
      ],
      [],
    );
    expect(report).toEqual({ uncovered: [], stale: ['GET /api/auth/old'] });
  });

  it('every non-public route has a case and public routes have none', () => {
    const caseKeys = new Set(registeredCases().map((c) => `${c.method} ${c.path}`));
    for (const key of PUBLIC_ROUTES) expect(caseKeys.has(key)).toBe(false);
  });
});
