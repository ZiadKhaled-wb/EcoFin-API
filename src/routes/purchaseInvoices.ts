import { Router } from 'express';
import {
  PurchaseInvoiceCreateBody,
  PurchaseInvoiceIdParams,
  PurchaseInvoiceListQuery,
  PurchaseInvoiceRejectBody,
  PurchaseInvoiceUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/purchases.controller';
const router = Router();
// Reads: any purchasing read key (D53) and the caller's branches, checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: PurchaseInvoiceListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: PurchaseInvoiceIdParams }),
  asyncHandler(controller.get),
);
// The Idempotency-Key header is read by the controller (IdempotencyKeyHeader).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.invoice_create'),
  validate({ body: PurchaseInvoiceCreateBody }),
  asyncHandler(controller.create),
);
router.put(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.invoice_create'),
  validate({ params: PurchaseInvoiceIdParams, body: PurchaseInvoiceUpdateBody }),
  asyncHandler(controller.update),
);
// U06 adds the amount threshold in SQL.
router.post(
  '/:id/approve',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.invoice_approve'),
  validate({ params: PurchaseInvoiceIdParams }),
  asyncHandler(controller.approve),
);
router.post(
  '/:id/reject',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.invoice_approve'),
  validate({ params: PurchaseInvoiceIdParams, body: PurchaseInvoiceRejectBody }),
  asyncHandler(controller.reject),
);
export default router;
