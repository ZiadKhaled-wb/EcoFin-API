import { Router } from 'express';
import { SaleCreateBody, SaleIdParams, SaleQuoteBody } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/sales.controller';
const router = Router();
// S01 (D62). The quote reads only: it prices a cart for the caller's open shift.
router.post(
  '/quote',
  authenticate,
  loadRequestContext,
  requirePermission('sale.create'),
  validate({ body: SaleQuoteBody }),
  asyncHandler(controller.quote),
);
// The Idempotency-Key header is read by the controller (IdempotencyKeyHeader).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('sale.create'),
  validate({ body: SaleCreateBody }),
  asyncHandler(controller.create),
);
// Own sales with sale.create; with report.view or cash.view the sales of the caller's branches.
// Checked in SQL.
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: SaleIdParams }),
  asyncHandler(controller.get),
);
export default router;
