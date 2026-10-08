import { Router } from 'express';
import { StockListQuery, StockMovementsQuery } from '@ziadkhaled-wb/contracts';
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
export default router;
