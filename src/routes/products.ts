import { Router } from 'express';
import {
  ProductCreateBody,
  ProductIdParams,
  ProductListQuery,
  ProductLookupQuery,
  ProductUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/products.controller';
const router = Router();
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ProductListQuery }),
  asyncHandler(controller.list),
);
// Before /:id, so "lookup" is never read as an id.
router.get(
  '/lookup',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ProductLookupQuery }),
  asyncHandler(controller.lookup),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: ProductIdParams }),
  asyncHandler(controller.get),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('catalog.manage'),
  validate({ body: ProductCreateBody }),
  asyncHandler(controller.create),
);
// catalog.price_change is checked in SQL, and only when a price actually changes.
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('catalog.manage'),
  validate({ params: ProductIdParams, body: ProductUpdateBody }),
  asyncHandler(controller.update),
);
router.post(
  '/:id/archive',
  authenticate,
  loadRequestContext,
  requirePermission('catalog.manage'),
  validate({ params: ProductIdParams }),
  asyncHandler(controller.archive),
);
router.post(
  '/:id/restore',
  authenticate,
  loadRequestContext,
  requirePermission('catalog.manage'),
  validate({ params: ProductIdParams }),
  asyncHandler(controller.restore),
);
export default router;
