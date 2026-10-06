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
      ]),
    );
    expect(keys).toHaveLength(18);
  });

  it('a new route without a case fails (exit 1) and is named', () => {
    const app = createApp({ env });
    const extra = Router();
    extra.get('/:id', (_req, res) => {
      res.json({});
    });
    mountRouter(app, '/api/products', extra);
    const lines: string[] = [];
    expect(runCrossShopCheck(app, registeredCases(), (l) => lines.push(l))).toBe(1);
    expect(lines).toContain(
      'MISSING cross-shop case: GET /api/products/:id (add one in src/test/cross-shop/cases.ts)',
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
