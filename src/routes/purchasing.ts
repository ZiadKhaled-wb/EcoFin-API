import { Router } from 'express';
import { PayableCashAccountQuery } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/purchases.controller';
const router = Router();
// U04 decision 8 (also U03): the active safes and banks money can move through for a branch.
// SQL checks purchase.return_create or supplier.payment_create, and the branch.
router.get(
  '/cash-accounts',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: PayableCashAccountQuery }),
  asyncHandler(controller.cashAccounts),
);
export default router;
