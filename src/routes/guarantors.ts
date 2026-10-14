import { Router } from 'express';
import {
  GuarantorCreateBody,
  GuarantorIdParams,
  GuarantorListQuery,
  GuarantorUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/guarantors.controller';
const router = Router();
// Reads: any customer read key (D63 rule 6) and the plan module, both checked in SQL, so they are
// authenticatedOnly() here. The national ID is masked in SQL unless the caller has customer.view_pii.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: GuarantorListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: GuarantorIdParams }),
  asyncHandler(controller.get),
);
// Create: guarantor.manage OR customer.create (a cashier registers the guarantors at the counter).
// There is no any-of marker, so the route is authenticatedOnly() and the database function is the
// authority: it asks for either key and refuses everyone else with PERMISSION_DENIED.
router.post(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ body: GuarantorCreateBody }),
  asyncHandler(controller.create),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('guarantor.manage'),
  validate({ params: GuarantorIdParams, body: GuarantorUpdateBody }),
  asyncHandler(controller.update),
);
router.post(
  '/:id/archive',
  authenticate,
  loadRequestContext,
  requirePermission('guarantor.manage'),
  validate({ params: GuarantorIdParams }),
  asyncHandler(controller.archive),
);
router.post(
  '/:id/restore',
  authenticate,
  loadRequestContext,
  requirePermission('guarantor.manage'),
  validate({ params: GuarantorIdParams }),
  asyncHandler(controller.restore),
);
export default router;
