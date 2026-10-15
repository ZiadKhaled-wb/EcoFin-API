import { Router } from 'express';
import {
  CreditExceptionDecideBody,
  CreditExceptionIdParams,
  CreditExceptionListQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/credit.controller';
const router = Router();
// R03 (D72): credit exceptions (approvals on the spot, copied from S03). Reads: the customer read
// guard in SQL (any customer read key + the plan module, works in an expired shop), so
// authenticatedOnly() here. Cancel: sale.create OR credit.approve and only the requester's own
// request; there is no any-of marker, so authenticatedOnly() and the database function asks.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: CreditExceptionListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CreditExceptionIdParams }),
  asyncHandler(controller.get),
);
router.post(
  '/:id/decide',
  authenticate,
  loadRequestContext,
  requirePermission('credit.approve'),
  validate({ params: CreditExceptionIdParams, body: CreditExceptionDecideBody }),
  asyncHandler(controller.decide),
);
router.post(
  '/:id/cancel',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CreditExceptionIdParams }),
  asyncHandler(controller.cancel),
);
export default router;
