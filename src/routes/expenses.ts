import { Router } from 'express';
import {
  ExpenseCreateBody,
  ExpenseIdParams,
  ExpenseListQuery,
  ExpenseReportQuery,
  ExpenseReverseBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/expenses.controller';
const router = Router();
// K03 (D61). Reads: expense.create, cash.view or report.financial and the caller's branches,
// checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ExpenseListQuery }),
  asyncHandler(controller.list),
);
// Before /:id.
router.get(
  '/report',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ExpenseReportQuery }),
  asyncHandler(controller.report),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: ExpenseIdParams }),
  asyncHandler(controller.get),
);
// The Idempotency-Key header is read by the controller (IdempotencyKeyHeader).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('expense.create'),
  validate({ body: ExpenseCreateBody }),
  asyncHandler(controller.create),
);
// Only the owner reverses; that is checked in SQL (APPROVAL_OWNER_ONLY).
router.post(
  '/:id/reverse',
  authenticate,
  loadRequestContext,
  requirePermission('expense.create'),
  validate({ params: ExpenseIdParams, body: ExpenseReverseBody }),
  asyncHandler(controller.reverse),
);
export default router;
