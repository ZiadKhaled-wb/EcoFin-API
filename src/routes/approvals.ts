import { Router } from 'express';
import {
  DiscountApprovalDecideBody,
  DiscountApprovalIdParams,
  DiscountApprovalListQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/sales.controller';
const router = Router();
// S03 (D65): the over-cap discount requests of the caller's branches, and the manager's decision.
// The requester can't decide their own request (APPROVAL_SELF). Purchase approvals (U06) stay on
// /api/purchase-approvals.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('discount.above_cap'),
  validate({ query: DiscountApprovalListQuery }),
  asyncHandler(controller.listApprovals),
);
router.post(
  '/:id/decide',
  authenticate,
  loadRequestContext,
  requirePermission('discount.above_cap'),
  validate({ params: DiscountApprovalIdParams, body: DiscountApprovalDecideBody }),
  asyncHandler(controller.decideApproval),
);
export default router;
