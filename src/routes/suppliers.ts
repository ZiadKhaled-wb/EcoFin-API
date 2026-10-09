import { Router } from 'express';
import {
  SupplierCreateBody,
  SupplierIdParams,
  SupplierListQuery,
  SupplierStatementQuery,
  SupplierUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/suppliers.controller';
const router = Router();
// Reads: any purchasing read key (D53), checked in SQL, so they are authenticatedOnly() here.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: SupplierListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: SupplierIdParams }),
  asyncHandler(controller.get),
);
router.get(
  '/:id/statement',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: SupplierIdParams, query: SupplierStatementQuery }),
  asyncHandler(controller.statement),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('supplier.manage'),
  validate({ body: SupplierCreateBody }),
  asyncHandler(controller.create),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('supplier.manage'),
  validate({ params: SupplierIdParams, body: SupplierUpdateBody }),
  asyncHandler(controller.update),
);
router.post(
  '/:id/archive',
  authenticate,
  loadRequestContext,
  requirePermission('supplier.manage'),
  validate({ params: SupplierIdParams }),
  asyncHandler(controller.archive),
);
router.post(
  '/:id/restore',
  authenticate,
  loadRequestContext,
  requirePermission('supplier.manage'),
  validate({ params: SupplierIdParams }),
  asyncHandler(controller.restore),
);
export default router;
