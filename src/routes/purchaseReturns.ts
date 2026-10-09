import { Router } from 'express';
import {
  PurchaseReturnCreateBody,
  PurchaseReturnIdParams,
  PurchaseReturnListQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/purchases.controller';
const router = Router();
// U04 (D57). Reads: any purchasing read key (D53) and the caller's branches, checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: PurchaseReturnListQuery }),
  asyncHandler(controller.listReturns),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: PurchaseReturnIdParams }),
  asyncHandler(controller.getReturn),
);
// The Idempotency-Key header is read by the controller (IdempotencyKeyHeader).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.return_create'),
  validate({ body: PurchaseReturnCreateBody }),
  asyncHandler(controller.postReturn),
);
export default router;
