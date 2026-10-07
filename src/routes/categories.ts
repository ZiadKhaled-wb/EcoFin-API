import { Router } from 'express';
import {
  CategoryArchiveBody,
  CategoryCreateBody,
  CategoryIdParams,
  CategoryUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/categories.controller';
const router = Router();
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate(),
  asyncHandler(controller.list),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('catalog.manage'),
  validate({ body: CategoryCreateBody }),
  asyncHandler(controller.create),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('catalog.manage'),
  validate({ params: CategoryIdParams, body: CategoryUpdateBody }),
  asyncHandler(controller.update),
);
router.post(
  '/:id/archive',
  authenticate,
  loadRequestContext,
  requirePermission('catalog.manage'),
  validate({ params: CategoryIdParams, body: CategoryArchiveBody }),
  asyncHandler(controller.archive),
);
router.post(
  '/:id/restore',
  authenticate,
  loadRequestContext,
  requirePermission('catalog.manage'),
  validate({ params: CategoryIdParams }),
  asyncHandler(controller.restore),
);
export default router;
