import { Router } from 'express';
import {
  CashAccountIdParams,
  CashTransferCreateBody,
  CashTransferListQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/cash.controller';
const router = Router();
// K01 transfers between safes and banks (D56): reads with cash.view; create with cash.transfer
// (the source account's branch is checked in SQL).
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('cash.view'),
  validate({ query: CashTransferListQuery }),
  asyncHandler(controller.listTransfers),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('cash.view'),
  validate({ params: CashAccountIdParams }),
  asyncHandler(controller.getTransfer),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('cash.transfer'),
  validate({ body: CashTransferCreateBody }),
  asyncHandler(controller.createTransfer),
);
export default router;
