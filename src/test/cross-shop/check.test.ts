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
        'POST /api/stock/movements/export',
        'GET /api/stock/low-summary',
        'GET /api/stock/min-levels/:id',
        'PUT /api/stock/min-levels/:id',
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
        'GET /api/units',
        'GET /api/units/find',
        'GET /api/units/:id',
        'POST /api/units',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /api/suppliers',
        'GET /api/suppliers/:id',
        'GET /api/suppliers/:id/statement',
        'POST /api/suppliers',
        'PATCH /api/suppliers/:id',
        'POST /api/suppliers/:id/archive',
        'POST /api/suppliers/:id/restore',
        'GET /api/purchase-invoices',
        'GET /api/purchase-invoices/:id',
        'POST /api/purchase-invoices',
        'PUT /api/purchase-invoices/:id',
        'POST /api/purchase-invoices/:id/approve',
        'POST /api/purchase-invoices/:id/reject',
        'GET /api/purchase-approvals',
        'GET /api/cash-accounts',
        'GET /api/cash-accounts/:id',
        'GET /api/cash-accounts/:id/movements',
        'POST /api/cash-accounts',
        'PATCH /api/cash-accounts/:id',
        'POST /api/cash-accounts/:id/deactivate',
        'POST /api/cash-accounts/:id/reactivate',
        'POST /api/cash-accounts/:id/opening',
        'GET /api/cash-transfers',
        'GET /api/cash-transfers/:id',
        'POST /api/cash-transfers',
        'GET /api/purchase-returns',
        'GET /api/purchase-returns/:id',
        'POST /api/purchase-returns',
        'GET /api/purchase-invoices/:id/returnable',
        'GET /api/purchasing/cash-accounts',
        'GET /api/supplier-payments',
        'GET /api/supplier-payments/open-invoices',
        'GET /api/supplier-payments/:id',
        'POST /api/supplier-payments',
        'POST /api/supplier-payments/:id/reverse',
        'GET /api/purchase-orders',
        'GET /api/purchase-orders/:id',
        'POST /api/purchase-orders',
        'PUT /api/purchase-orders/:id',
        'POST /api/purchase-orders/:id/send',
        'POST /api/purchase-orders/:id/cancel',
        'POST /api/purchase-orders/:id/invoice',
        'GET /api/shifts',
        'GET /api/shifts/current',
        'GET /api/shifts/vaults',
        'GET /api/shifts/:id',
        'POST /api/shifts',
        'POST /api/shifts/:id/cash',
        'POST /api/shifts/:id/close',
        'POST /api/shifts/:id/force-close',
        'GET /api/expense-categories',
        'POST /api/expense-categories',
        'PATCH /api/expense-categories/:id',
        'POST /api/expense-categories/:id/archive',
        'POST /api/expense-categories/:id/restore',
        'GET /api/expenses',
        'GET /api/expenses/report',
        'GET /api/expenses/:id',
        'POST /api/expenses',
        'POST /api/expenses/:id/reverse',
        'GET /api/sales/payment-accounts',
        'POST /api/sales/quote',
        'POST /api/sales',
        'GET /api/sales/:id',
        'POST /api/sales/:id/receipt-prints',
        'GET /api/customers',
        'GET /api/customers/:id',
        'POST /api/customers',
        'PATCH /api/customers/:id',
        'POST /api/customers/:id/status',
        'GET /api/guarantors',
        'GET /api/guarantors/:id',
        'POST /api/guarantors',
        'PATCH /api/guarantors/:id',
        'POST /api/guarantors/:id/archive',
        'POST /api/guarantors/:id/restore',
        'GET /api/customers/:id/guarantors',
        'POST /api/customers/:id/guarantors',
        'PATCH /api/customers/:id/guarantors/:guarantorId',
        'POST /api/customers/:id/guarantors/:guarantorId/unlink',
        'GET /api/customers/:id/guarantor-requirement',
        'GET /api/customers/:id/credit',
        'PUT /api/customers/:id/credit-limit',
        'GET /api/customers/:id/credit-check',
        'POST /api/customers/:id/credit-exceptions',
        'GET /api/credit-exceptions',
        'GET /api/credit-exceptions/:id',
        'POST /api/credit-exceptions/:id/decide',
        'POST /api/credit-exceptions/:id/cancel',
        'GET /api/customers/:id/account',
        'GET /api/customers/:id/contracts/:contractId/schedule',
        'GET /api/customers/:id/statement',
        'GET /api/surveys',
        'GET /api/surveys/:id',
        'POST /api/surveys',
        'POST /api/surveys/:id/reassign',
        'POST /api/surveys/:id/cancel',
        'PATCH /api/surveys/:id',
        'POST /api/surveys/:id/submit',
        'POST /api/surveys/:id/decide',
        'GET /api/customers/:id/surveys',
        'GET /api/customers/:id/survey-requirement',
        'POST /api/installments/preview',
        'POST /api/installments/sales',
        'GET /api/contracts/:id',
        'GET /api/contracts',
        'GET /api/contracts/:id/collection',
        'POST /api/collections',
        'GET /api/collections/:id',
        'POST /api/collections/:id/prints',
        'POST /api/collections/:id/reverse',
        'GET /api/overdue',
        'GET /api/overdue/warnings',
        'POST /api/overdue/warnings/:id/handle',
        'GET /api/overdue/legal-referrals',
        'POST /api/overdue/legal-referrals/:id/dismiss',
        'POST /api/overdue/run',
        'GET /api/contracts/:id/settlement-quote',
        'POST /api/contracts/:id/settle',
        'POST /api/contracts/:id/reschedule/preview',
        'POST /api/contracts/:id/reschedule',
        'POST /api/contracts/:id/write-off',
        'GET /api/contracts/:id/changes',
        'GET /api/contracts/:id/documents',
        'POST /api/contracts/:id/document-prints',
        'GET /api/contract-changes',
        'POST /api/collections/field',
        'GET /api/wallets/me',
        'GET /api/wallets',
        'GET /api/wallets/:id/movements',
        'POST /api/wallets/:id/settle',
        'PUT /api/customers/:id/collector',
        'GET /api/collectors/route',
        'GET /api/eta/settings',
        'PUT /api/eta/settings',
        'POST /api/eta/settings/test',
        'POST /api/eta/submissions/:id/retry',
        'GET /api/devices',
        'PUT /api/devices/:id/eta',
        'POST /api/devices',
        'GET /api/devices/current',
        'POST /api/devices/pair',
        'PATCH /api/devices/:id',
        'POST /api/devices/:id/active',
        'POST /api/devices/:id/pairing-code',
        'POST /api/devices/:id/unpair',
        'GET /api/fiscal',
        'GET /api/fiscal/summary',
        'GET /api/fiscal/day-summary',
        'GET /api/fiscal/:id',
        'POST /api/fiscal/:id/retry',
        'POST /api/fiscal/:id/correct',
        'POST /api/fiscal/:id/assign-device',
        'POST /api/fiscal/:id/check-now',
        'POST /api/fiscal/retry-many',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /api/imports/templates/:kind',
        'POST /api/imports/inspect',
        'GET /api/imports',
        'POST /api/imports',
        'GET /api/imports/:id',
        'POST /api/imports/:id/run',
        'POST /api/imports/:id/cancel',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /api/day-closes',
        'GET /api/day-closes/preview',
        'GET /api/day-closes/alerts',
        'GET /api/day-closes/:id',
        'POST /api/day-closes',
        'POST /api/day-closes/:id/reopen',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /api/migration/report',
        'GET /api/migration/sign-offs',
        'POST /api/migration/sign-offs',
        'POST /api/migration/batches/:id/reverse',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'POST /api/exports',
        'GET /api/exports',
        'GET /api/exports/:id',
        'POST /api/exports/:id/cancel',
      ]),
    );
    expect(keys).toEqual(
      expect.arrayContaining([
        'GET /api/sales/:id/returnable',
        'POST /api/returns/quote',
        'POST /api/returns',
        'GET /api/returns',
        'GET /api/returns/:id',
        'POST /api/returns/:id/receipt-prints',
      ]),
    );
    expect(keys).toHaveLength(293);
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
