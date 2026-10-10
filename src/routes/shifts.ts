import { Router } from 'express';
import {
  ShiftCashBody,
  ShiftCloseBody,
  ShiftIdParams,
  ShiftListQuery,
  ShiftOpenBody,
  ShiftVaultQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/shifts.controller';
const router = Router();
// K02 (D60). Reads: shift.operate (own shifts) or cash.view (the caller's branches), checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ShiftListQuery }),
  asyncHandler(controller.list),
);
// Static paths before /:id.
router.get(
  '/current',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  asyncHandler(controller.current),
);
router.get(
  '/vaults',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ShiftVaultQuery }),
  asyncHandler(controller.vaults),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: ShiftIdParams }),
  asyncHandler(controller.get),
);
// The Idempotency-Key header is read by the controller (IdempotencyKeyHeader).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('shift.operate'),
  validate({ body: ShiftOpenBody }),
  asyncHandler(controller.open),
);
router.post(
  '/:id/cash',
  authenticate,
  loadRequestContext,
  requirePermission('shift.operate'),
  validate({ params: ShiftIdParams, body: ShiftCashBody }),
  asyncHandler(controller.cash),
);
router.post(
  '/:id/close',
  authenticate,
  loadRequestContext,
  requirePermission('shift.operate'),
  validate({ params: ShiftIdParams, body: ShiftCloseBody }),
  asyncHandler(controller.close),
);
export default router;
