import { Router } from 'express';
import {
  ReturnIdParams,
  SalesReturnCreateBody,
  SalesReturnListQuery,
  SalesReturnQuoteBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/returns.controller';
const router = Router();
// S05 (D88). Reads: refund.create, sale.create, report.view or cash.view and the caller's
// branches, checked in SQL (an expired shop still reads).
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: SalesReturnListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: ReturnIdParams }),
  asyncHandler(controller.get),
);
// The quote needs the caller's open shift; nothing is written.
router.post(
  '/quote',
  authenticate,
  loadRequestContext,
  requirePermission('refund.create'),
  validate({ body: SalesReturnQuoteBody }),
  asyncHandler(controller.quote),
);
// The Idempotency-Key header is read by the controller (IdempotencyKeyHeader).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('refund.create'),
  validate({ body: SalesReturnCreateBody }),
  asyncHandler(controller.post),
);
// S04: SQL checks refund.create, sale.create or report.view, plus the return's branch.
router.post(
  '/:id/receipt-prints',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: ReturnIdParams }),
  asyncHandler(controller.recordReceiptPrint),
);
export default router;
