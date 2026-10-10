import { Router } from 'express';
import {
  CustomerCreateBody,
  CustomerIdParams,
  CustomerListQuery,
  CustomerStatusBody,
  CustomerUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/customers.controller';
const router = Router();
// Reads: any customer read key (D63 rule 6) and the plan module, both checked in SQL, so they are
// authenticatedOnly() here. The national ID is masked in SQL unless the caller has customer.view_pii.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: CustomerListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams }),
  asyncHandler(controller.get),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('customer.create'),
  validate({ body: CustomerCreateBody }),
  asyncHandler(controller.create),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('customer.edit'),
  validate({ params: CustomerIdParams, body: CustomerUpdateBody }),
  asyncHandler(controller.update),
);
router.post(
  '/:id/status',
  authenticate,
  loadRequestContext,
  requirePermission('customer.edit'),
  validate({ params: CustomerIdParams, body: CustomerStatusBody }),
  asyncHandler(controller.setStatus),
);
export default router;
