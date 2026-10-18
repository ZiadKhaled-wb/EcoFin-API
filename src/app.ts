import salesHistoryRoutes from './routes/salesHistory';
// server/src/app.ts
import express from 'express';
import type { Router } from 'express';
import auditRoutes from './routes/audit.js';
import adminRoutes from './routes/admin.js';
import subscriptionRoutes from './routes/subscription.js';
import branchesRoutes from './routes/branches.js';
import monitoringRoutes from './routes/monitoring.js';
import authRoutes from './routes/auth.js';
import employeesRoutes from './routes/employees.js';
import warrantyRoutes from './routes/warranty.js';
import filesRoutes from './routes/files.js';
import healthRoutes from './routes/health.js';
import meRoutes from './routes/me.js';
import settingsRoutes from './routes/settings.js';
import taxClassesRoutes from './routes/taxClasses.js';
import categoriesRoutes from './routes/categories.js';
import productsRoutes from './routes/products.js';
import stockRoutes from './routes/stock.js';
import unitsRoutes from './routes/units.js';
import suppliersRoutes from './routes/suppliers.js';
import purchaseInvoicesRoutes from './routes/purchaseInvoices.js';
import purchaseApprovalsRoutes from './routes/purchaseApprovals.js';
import purchaseReturnsRoutes from './routes/purchaseReturns.js';
import purchasingRoutes from './routes/purchasing.js';
import supplierPaymentsRoutes from './routes/supplierPayments.js';
import purchaseOrdersRoutes from './routes/purchaseOrders.js';
import shiftsRoutes from './routes/shifts.js';
import expenseCategoriesRoutes from './routes/expenseCategories.js';
import expensesRoutes from './routes/expenses.js';
import salesRoutes from './routes/sales.js';
import approvalsRoutes from './routes/approvals.js';
import customersRoutes from './routes/customers.js';
import guarantorsRoutes from './routes/guarantors.js';
import surveysRoutes from './routes/surveys.js';
import installmentsRoutes from './routes/installments.js';
import contractsRoutes from './routes/contracts.js';
import collectionsRoutes from './routes/collections.js';
import overdueRoutes from './routes/overdue.js';
import contractChangeRoutes from './routes/contractChanges.js';
import creditRoutes from './routes/credit.js';
import cashAccountsRoutes from './routes/cashAccounts.js';
import cashTransfersRoutes from './routes/cashTransfers.js';
import etaRoutes from './routes/eta.js';
import fiscalRoutes from './routes/fiscal.js';
import devicesRoutes from './routes/devices.js';
import { errorHandler, notFoundHandler } from './middleware/errorHandler.js';
import { noClientOrg } from './middleware/noClientOrg.js';
import { requestId } from './middleware/requestId.js';
import { mountRouter } from './routes/registry.js';
import { corsAllowList, securityHeaders } from './middleware/security.js';
import { getEnv, type Env } from './utils/env.js';

export interface CreateAppOptions {
  /** Swagger UI router, mounted at /docs. */
  docsRouter?: Router;
  /** Parsed env. Defaults to the cached process env (validated on startup). */
  env?: Pick<Env, 'TRUST_PROXY' | 'CORS_ALLOWED_ORIGINS'>;
}

export function createApp(options: CreateAppOptions = {}) {
  const env = options.env ?? getEnv();
  const app = express();

  // Number of reverse-proxy hops to trust for req.ip (and so the rate limiter's key).
  app.set('trust proxy', env.TRUST_PROXY);
  app.disable('x-powered-by');

  app.use(requestId());
  app.use(securityHeaders());
  app.use(corsAllowList(env.CORS_ALLOWED_ORIGINS));
  app.use(express.json({ limit: '1mb' }));
  // F05: the shop comes from the session, never from the body or query.
  app.use(noClientOrg);

  // Routers go through mountRouter so listRoutes() (D19 route checks) can see them.
  mountRouter(app, '/health', healthRoutes);

  // API docs — no auth, dev-only by default. Mount BEFORE the 404 handler.
  if (options.docsRouter) mountRouter(app, '/docs', options.docsRouter);

  mountRouter(app, '/api/auth', authRoutes);
  mountRouter(app, '/api/admin', adminRoutes);
  mountRouter(app, '/api/subscription', subscriptionRoutes);
  mountRouter(app, '/api/branches', branchesRoutes);
  mountRouter(app, '/api/settings', settingsRoutes);
  mountRouter(app, '/api/tax-classes', taxClassesRoutes);
  mountRouter(app, '/api/categories', categoriesRoutes);
  mountRouter(app, '/api/products', productsRoutes);
  mountRouter(app, '/api/stock', stockRoutes);
  mountRouter(app, '/api/units', unitsRoutes);
  mountRouter(app, '/api/suppliers', suppliersRoutes);
  mountRouter(app, '/api/purchase-invoices', purchaseInvoicesRoutes);
  mountRouter(app, '/api/purchase-approvals', purchaseApprovalsRoutes);
  mountRouter(app, '/api/purchase-returns', purchaseReturnsRoutes);
  mountRouter(app, '/api/purchasing', purchasingRoutes);
  mountRouter(app, '/api/supplier-payments', supplierPaymentsRoutes);
  mountRouter(app, '/api/purchase-orders', purchaseOrdersRoutes);
  mountRouter(app, '/api/shifts', shiftsRoutes);
  mountRouter(app, '/api/expense-categories', expenseCategoriesRoutes);
  mountRouter(app, '/api/expenses', expensesRoutes);
  mountRouter(app, '/api/sales', salesHistoryRoutes);
  mountRouter(app, '/api/sales', salesRoutes);
  mountRouter(app, '/api/approvals', approvalsRoutes);
  mountRouter(app, '/api/customers', customersRoutes);
  mountRouter(app, '/api/guarantors', guarantorsRoutes);
  mountRouter(app, '/api/surveys', surveysRoutes);
  mountRouter(app, '/api/installments', installmentsRoutes);
  mountRouter(app, '/api/contracts', contractsRoutes);
  mountRouter(app, '/api/collections', collectionsRoutes);
  mountRouter(app, '/api/overdue', overdueRoutes);
  mountRouter(app, '/api/contract-changes', contractChangeRoutes);
  mountRouter(app, '/api/credit-exceptions', creditRoutes);
  mountRouter(app, '/api/cash-accounts', cashAccountsRoutes);
  mountRouter(app, '/api/cash-transfers', cashTransfersRoutes);
  mountRouter(app, '/api/eta', etaRoutes);
  mountRouter(app, '/api/fiscal', fiscalRoutes);
  mountRouter(app, '/api/devices', devicesRoutes);
  mountRouter(app, '/api/me', meRoutes);
  mountRouter(app, '/api/employees', employeesRoutes);
  mountRouter(app, '/api/warranty', warrantyRoutes);
  mountRouter(app, '/api/files', filesRoutes);
  mountRouter(app, '/api/audit', auditRoutes);
  mountRouter(app, '/api/monitoring', monitoringRoutes);

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
