import { Router } from 'express';
import {
  UnitFindQuery,
  UnitIdParams,
  UnitRegisterBody,
  UnitSearchQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/units.controller';
const router = Router();
// I04 serial units: reads with stock.view (the unit's branch is checked in SQL); registering with
// stock.adjust (+ the serials module and the branch, checked in SQL).
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('stock.view'),
  validate({ query: UnitSearchQuery }),
  asyncHandler(controller.search),
);
// Before /:id, so "find" is never read as an id.
router.get(
  '/find',
  authenticate,
  loadRequestContext,
  requirePermission('stock.view'),
  validate({ query: UnitFindQuery }),
  asyncHandler(controller.find),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('stock.view'),
  validate({ params: UnitIdParams }),
  asyncHandler(controller.get),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('stock.adjust'),
  validate({ body: UnitRegisterBody }),
  asyncHandler(controller.register),
);
export default router;
