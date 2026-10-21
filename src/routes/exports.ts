import { Router } from 'express';
import { ExportIdParams, StartExportBody } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/exports.controller';
const router = Router();
// M03 (D86). export.data is the one key that works in an expired shop (P05): the way out of the
// system. A suspended shop is refused in SQL (app.require_permission).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('export.data'),
  validate({ body: StartExportBody }),
  asyncHandler(controller.start),
);
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('export.data'),
  asyncHandler(controller.list),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('export.data'),
  validate({ params: ExportIdParams }),
  asyncHandler(controller.get),
);
router.post(
  '/:id/cancel',
  authenticate,
  loadRequestContext,
  requirePermission('export.data'),
  validate({ params: ExportIdParams }),
  asyncHandler(controller.cancel),
);
export default router;
