import { Router } from 'express';
import {
  CashAccountCreateBody,
  CashAccountIdParams,
  CashAccountListQuery,
  CashAccountUpdateBody,
  CashLedgerQuery,
  CashOpeningBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/cash.controller';
const router = Router();
// K01 vaults (D56): reads with cash.view (also in an expired shop); branches are checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('cash.view'),
  validate({ query: CashAccountListQuery }),
  asyncHandler(controller.listAccounts),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('cash.view'),
  validate({ params: CashAccountIdParams }),
  asyncHandler(controller.getAccount),
);
router.get(
  '/:id/movements',
  authenticate,
  loadRequestContext,
  requirePermission('cash.view'),
  validate({ params: CashAccountIdParams, query: CashLedgerQuery }),
  asyncHandler(controller.ledger),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('cash.account_manage'),
  validate({ body: CashAccountCreateBody }),
  asyncHandler(controller.createAccount),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('cash.account_manage'),
  validate({ params: CashAccountIdParams, body: CashAccountUpdateBody }),
  asyncHandler(controller.renameAccount),
);
router.post(
  '/:id/deactivate',
  authenticate,
  loadRequestContext,
  requirePermission('cash.account_manage'),
  validate({ params: CashAccountIdParams }),
  asyncHandler(controller.deactivate),
);
router.post(
  '/:id/reactivate',
  authenticate,
  loadRequestContext,
  requirePermission('cash.account_manage'),
  validate({ params: CashAccountIdParams }),
  asyncHandler(controller.reactivate),
);
router.post(
  '/:id/opening',
  authenticate,
  loadRequestContext,
  requirePermission('cash.adjust'),
  validate({ params: CashAccountIdParams, body: CashOpeningBody }),
  asyncHandler(controller.opening),
);
export default router;
