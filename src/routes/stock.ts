import { Router } from 'express';
import {
  StockAdjustmentCreateBody,
  StockAdjustmentListQuery,
  StockCountCreateBody,
  StockCountDetailQuery,
  StockCountLinesBody,
  StockCountListQuery,
  StockCountPostBody,
  StockCountScanBody,
  StockDocumentIdParams,
  StockListQuery,
  StockMovementsQuery,
  StockTransferCreateBody,
  StockTransferListQuery,
  StockTransferReceiveBody,
  StockTransferUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/stock.controller';
const router = Router();
// I01 stock view; branches are limited to the caller's in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('stock.view'),
  validate({ query: StockListQuery }),
  asyncHandler(controller.list),
);
// I01 drill-down to the ledger (I05 extends it).
router.get(
  '/movements',
  authenticate,
  loadRequestContext,
  requirePermission('stock.view'),
  validate({ query: StockMovementsQuery }),
  asyncHandler(controller.movements),
);
// I02 adjustments: read with stock.view, post with stock.adjust (Idempotency-Key).
router.get(
  '/adjustments',
  authenticate,
  loadRequestContext,
  requirePermission('stock.view'),
  validate({ query: StockAdjustmentListQuery }),
  asyncHandler(controller.listAdjustments),
);
router.get(
  '/adjustments/:id',
  authenticate,
  loadRequestContext,
  requirePermission('stock.view'),
  validate({ params: StockDocumentIdParams }),
  asyncHandler(controller.getAdjustment),
);
router.post(
  '/adjustments',
  authenticate,
  loadRequestContext,
  requirePermission('stock.adjust'),
  validate({ body: StockAdjustmentCreateBody }),
  asyncHandler(controller.postAdjustment),
);
// I02 counts: everything with stock.count; create and post take an Idempotency-Key.
router.get(
  '/counts',
  authenticate,
  loadRequestContext,
  requirePermission('stock.count'),
  validate({ query: StockCountListQuery }),
  asyncHandler(controller.listCounts),
);
router.post(
  '/counts',
  authenticate,
  loadRequestContext,
  requirePermission('stock.count'),
  validate({ body: StockCountCreateBody }),
  asyncHandler(controller.createCount),
);
router.get(
  '/counts/:id',
  authenticate,
  loadRequestContext,
  requirePermission('stock.count'),
  validate({ params: StockDocumentIdParams, query: StockCountDetailQuery }),
  asyncHandler(controller.getCount),
);
router.put(
  '/counts/:id/lines',
  authenticate,
  loadRequestContext,
  requirePermission('stock.count'),
  validate({ params: StockDocumentIdParams, body: StockCountLinesBody }),
  asyncHandler(controller.saveCountLines),
);
router.post(
  '/counts/:id/scan',
  authenticate,
  loadRequestContext,
  requirePermission('stock.count'),
  validate({ params: StockDocumentIdParams, body: StockCountScanBody }),
  asyncHandler(controller.scanCount),
);
router.post(
  '/counts/:id/post',
  authenticate,
  loadRequestContext,
  requirePermission('stock.count'),
  validate({ params: StockDocumentIdParams, body: StockCountPostBody }),
  asyncHandler(controller.postCount),
);
router.post(
  '/counts/:id/cancel',
  authenticate,
  loadRequestContext,
  requirePermission('stock.count'),
  validate({ params: StockDocumentIdParams }),
  asyncHandler(controller.cancelCount),
);
// I03 transfers: read with stock.view; draft, send and cancel with stock.transfer_send (source
// branch), receive with stock.transfer_receive (destination branch); branches are checked in SQL.
router.get(
  '/transfers',
  authenticate,
  loadRequestContext,
  requirePermission('stock.view'),
  validate({ query: StockTransferListQuery }),
  asyncHandler(controller.listTransfers),
);
router.post(
  '/transfers',
  authenticate,
  loadRequestContext,
  requirePermission('stock.transfer_send'),
  validate({ body: StockTransferCreateBody }),
  asyncHandler(controller.createTransfer),
);
// Before /transfers/:id, so "destinations" is never read as an id.
router.get(
  '/transfers/destinations',
  authenticate,
  loadRequestContext,
  requirePermission('stock.transfer_send'),
  validate(),
  asyncHandler(controller.transferDestinations),
);
router.get(
  '/transfers/:id',
  authenticate,
  loadRequestContext,
  requirePermission('stock.view'),
  validate({ params: StockDocumentIdParams }),
  asyncHandler(controller.getTransfer),
);
router.put(
  '/transfers/:id',
  authenticate,
  loadRequestContext,
  requirePermission('stock.transfer_send'),
  validate({ params: StockDocumentIdParams, body: StockTransferUpdateBody }),
  asyncHandler(controller.updateTransfer),
);
router.post(
  '/transfers/:id/send',
  authenticate,
  loadRequestContext,
  requirePermission('stock.transfer_send'),
  validate({ params: StockDocumentIdParams }),
  asyncHandler(controller.sendTransfer),
);
router.post(
  '/transfers/:id/receive',
  authenticate,
  loadRequestContext,
  requirePermission('stock.transfer_receive'),
  validate({ params: StockDocumentIdParams, body: StockTransferReceiveBody }),
  asyncHandler(controller.receiveTransfer),
);
router.post(
  '/transfers/:id/cancel',
  authenticate,
  loadRequestContext,
  requirePermission('stock.transfer_send'),
  validate({ params: StockDocumentIdParams }),
  asyncHandler(controller.cancelTransfer),
);
export default router;
