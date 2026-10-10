import { Router } from 'express';
import {
  ExpenseCategoryBody,
  ExpenseCategoryIdParams,
  ExpenseCategoryListQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/expenses.controller';
const router = Router();
// K03 (D61). Read: expense.create, cash.view or report.financial, checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ExpenseCategoryListQuery }),
  asyncHandler(controller.listCategories),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('expense.create'),
  validate({ body: ExpenseCategoryBody }),
  asyncHandler(controller.createCategory),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('expense.create'),
  validate({ params: ExpenseCategoryIdParams, body: ExpenseCategoryBody }),
  asyncHandler(controller.renameCategory),
);
router.post(
  '/:id/archive',
  authenticate,
  loadRequestContext,
  requirePermission('expense.create'),
  validate({ params: ExpenseCategoryIdParams }),
  asyncHandler(controller.archiveCategory),
);
router.post(
  '/:id/restore',
  authenticate,
  loadRequestContext,
  requirePermission('expense.create'),
  validate({ params: ExpenseCategoryIdParams }),
  asyncHandler(controller.restoreCategory),
);
export default router;
