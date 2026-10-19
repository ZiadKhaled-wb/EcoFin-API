import { Router } from 'express';
import {
  SettleWalletBody,
  WalletIdParams,
  WalletListQuery,
  WalletMovementQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/wallets.controller';
const router = Router();
// N06 (D81). Collector wallets. The module, the branch access and the self-settlement rule are
// checked in SQL; an expired shop may still read. The Idempotency-Key header is read by the
// controller (IdempotencyKeyHeader). There is no commission and no shortage deduction.
router.get(
  '/me',
  authenticate,
  loadRequestContext,
  requirePermission('collection.create'),
  asyncHandler(controller.myWallet),
);
// collector.settle or cash.view, checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: WalletListQuery }),
  asyncHandler(controller.list),
);
// The collector's own ledger, or collector.settle / cash.view with branch access: checked in SQL.
router.get(
  '/:id/movements',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: WalletIdParams, query: WalletMovementQuery }),
  asyncHandler(controller.movements),
);
router.post(
  '/:id/settle',
  authenticate,
  loadRequestContext,
  requirePermission('collector.settle'),
  validate({ params: WalletIdParams, body: SettleWalletBody }),
  asyncHandler(controller.settle),
);
export default router;
