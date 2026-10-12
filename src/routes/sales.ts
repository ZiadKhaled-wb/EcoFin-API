import { Router } from 'express';
import {
  DiscountApprovalIdParams,
  DiscountApprovalRequestBody,
  SaleCreateBody,
  SaleIdParams,
  SaleQuoteBody,
} from '@ziadkhaled-wb/contracts';
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
// S02: the banks a transfer can go into (names only). Before `/:id`.
router.get(
  '/payment-accounts',
  authenticate,
  loadRequestContext,
  requirePermission('sale.create'),
  asyncHandler(controller.paymentAccounts),
);
// S03 (D65): the cashier asks for an over-cap discount approval, reads it and may take it back.
// The manager lists and decides these in routes/approvals.ts. Before `/:id`.
router.post(
  '/discount-approvals',
  authenticate,
  loadRequestContext,
  requirePermission('sale.create'),
  validate({ body: DiscountApprovalRequestBody }),
  asyncHandler(controller.requestApproval),
);
// The requester, or discount.above_cap: checked in SQL.
router.get(
  '/discount-approvals/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: DiscountApprovalIdParams }),
  asyncHandler(controller.getApproval),
);
router.post(
  '/discount-approvals/:id/cancel',
  authenticate,
  loadRequestContext,
  requirePermission('sale.create'),
  validate({ params: DiscountApprovalIdParams }),
  asyncHandler(controller.cancelApproval),
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
