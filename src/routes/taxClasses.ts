// T01 tax classes: every employee reads them (POS, product forms); catalog.manage changes them.
import { Router } from 'express';
import { TaxClassCreateBody, TaxClassIdParams, TaxClassUpdateBody } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/taxClasses.controller';

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
  validate({ body: TaxClassCreateBody }),
  asyncHandler(controller.create),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('catalog.manage'),
  validate({ params: TaxClassIdParams, body: TaxClassUpdateBody }),
  asyncHandler(controller.update),
);
for (const action of ['archive', 'restore'] as const)
  router.post(
    `/:id/${action}`,
    authenticate,
    loadRequestContext,
    requirePermission('catalog.manage'),
    validate({ params: TaxClassIdParams }),
    asyncHandler(controller[action]),
  );
export default router;
