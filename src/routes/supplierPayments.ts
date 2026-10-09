import { Router } from 'express';
import {
  OpenSupplierInvoiceQuery,
  SupplierPaymentCreateBody,
  SupplierPaymentIdParams,
  SupplierPaymentListQuery,
  SupplierPaymentReverseBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/supplierPayments.controller';
const router = Router();
// U03 (D58). Reads: any purchasing read key (D53) and the caller's branches, checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: SupplierPaymentListQuery }),
  asyncHandler(controller.list),
);
// Before /:id.
router.get(
  '/open-invoices',
  authenticate,
  loadRequestContext,
  requirePermission('supplier.payment_create'),
  validate({ query: OpenSupplierInvoiceQuery }),
  asyncHandler(controller.openInvoices),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: SupplierPaymentIdParams }),
  asyncHandler(controller.get),
);
// The Idempotency-Key header is read by the controller (IdempotencyKeyHeader).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('supplier.payment_create'),
  validate({ body: SupplierPaymentCreateBody }),
  asyncHandler(controller.create),
);
// Only the owner reverses; that is checked in SQL (APPROVAL_OWNER_ONLY).
router.post(
  '/:id/reverse',
  authenticate,
  loadRequestContext,
  requirePermission('supplier.payment_create'),
  validate({ params: SupplierPaymentIdParams, body: SupplierPaymentReverseBody }),
  asyncHandler(controller.reverse),
);
export default router;
