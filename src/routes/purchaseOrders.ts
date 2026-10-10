import { Router } from 'express';
import {
  PurchaseOrderCancelBody,
  PurchaseOrderCreateBody,
  PurchaseOrderIdParams,
  PurchaseOrderInvoiceBody,
  PurchaseOrderListQuery,
  PurchaseOrderUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/purchases.controller';
const router = Router();
// U05 (D59). Reads: any purchasing read key (D53) and the caller's branches, checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: PurchaseOrderListQuery }),
  asyncHandler(controller.listOrders),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: PurchaseOrderIdParams }),
  asyncHandler(controller.getOrder),
);
// The Idempotency-Key header is read by the controller (IdempotencyKeyHeader).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.order_manage'),
  validate({ body: PurchaseOrderCreateBody }),
  asyncHandler(controller.createOrder),
);
router.put(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.order_manage'),
  validate({ params: PurchaseOrderIdParams, body: PurchaseOrderUpdateBody }),
  asyncHandler(controller.updateOrder),
);
router.post(
  '/:id/send',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.order_manage'),
  validate({ params: PurchaseOrderIdParams }),
  asyncHandler(controller.sendOrder),
);
router.post(
  '/:id/cancel',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.order_manage'),
  validate({ params: PurchaseOrderIdParams, body: PurchaseOrderCancelBody }),
  asyncHandler(controller.cancelOrder),
);
// "Receive": a draft purchase invoice from the order, so it needs the invoice key.
router.post(
  '/:id/invoice',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.invoice_create'),
  validate({ params: PurchaseOrderIdParams, body: PurchaseOrderInvoiceBody }),
  asyncHandler(controller.invoiceOrder),
);
export default router;
