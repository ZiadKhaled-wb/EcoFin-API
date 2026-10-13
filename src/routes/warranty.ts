import { Router } from 'express';
import {
  WarrantyClaimsQuery,
  WarrantyClaimIdParams,
  OpenWarrantyClaimBody,
  MoveWarrantyClaimBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as c from '../controllers/warranty.controller';
const router = Router();
router.use(authenticate, loadRequestContext);
router.get('/lookup', requirePermission('warranty.manage'), asyncHandler(c.lookup));
router.get(
  '/claims',
  requirePermission('warranty.manage'),
  validate({ query: WarrantyClaimsQuery }),
  asyncHandler(c.list),
);
router.get(
  '/claims/:id',
  requirePermission('warranty.manage'),
  validate({ params: WarrantyClaimIdParams }),
  asyncHandler(c.get),
);
router.post(
  '/claims',
  requirePermission('warranty.manage'),
  validate({ body: OpenWarrantyClaimBody }),
  asyncHandler(c.open),
);
router.post(
  '/claims/:id/move',
  requirePermission('warranty.manage'),
  validate({ params: WarrantyClaimIdParams, body: MoveWarrantyClaimBody }),
  asyncHandler(c.move),
);
router.post(
  '/claims/:id/refund',
  requirePermission('warranty.manage'),
  validate({ params: WarrantyClaimIdParams }),
  asyncHandler(c.refund),
);
export default router;
