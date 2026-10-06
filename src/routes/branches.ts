import { Router } from 'express';
import {
  BranchCreateBody,
  BranchUpdateBody,
  BranchDeactivateBody,
  BranchIdParams,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/branches.controller';
const router = Router();
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate(),
  asyncHandler(controller.list),
);
router.get(
  '/manage',
  authenticate,
  loadRequestContext,
  requirePermission('branch.manage'),
  validate(),
  asyncHandler(controller.manage),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('branch.manage'),
  validate({ params: BranchIdParams }),
  asyncHandler(controller.detail),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('branch.manage'),
  validate({ body: BranchCreateBody }),
  asyncHandler(controller.create),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('branch.manage'),
  validate({ params: BranchIdParams, body: BranchUpdateBody }),
  asyncHandler(controller.update),
);
router.get(
  '/:id/deactivation-check',
  authenticate,
  loadRequestContext,
  requirePermission('branch.manage'),
  validate({ params: BranchIdParams }),
  asyncHandler(controller.check),
);
router.post(
  '/:id/deactivate',
  authenticate,
  loadRequestContext,
  requirePermission('branch.manage'),
  validate({ params: BranchIdParams, body: BranchDeactivateBody }),
  asyncHandler(controller.deactivate),
);
router.post(
  '/:id/reactivate',
  authenticate,
  loadRequestContext,
  requirePermission('branch.manage'),
  validate({ params: BranchIdParams }),
  asyncHandler(controller.reactivate),
);
export default router;
