import { Router } from 'express';
import { SaleIdParams, SalesHistoryQuery, SaleVoidBody } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/salesHistory.controller';
const router = Router();
// SQL checks sale.create OR report.view, plus accessible branches.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: SalesHistoryQuery }),
  asyncHandler(controller.list),
);
router.post(
  '/:id/void',
  authenticate,
  loadRequestContext,
  requirePermission('sale.void'),
  validate({ params: SaleIdParams, body: SaleVoidBody }),
  asyncHandler(controller.voidSale),
);
// S04: SQL checks sale.create OR report.view, plus accessible branches (whoever reads the sale).
router.post(
  '/:id/receipt-prints',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: SaleIdParams }),
  asyncHandler(controller.recordReceiptPrint),
);
export default router;
