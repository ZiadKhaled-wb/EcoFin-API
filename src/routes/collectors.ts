import { Router } from 'express';
import { CollectorRouteQuery } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/wallets.controller';
const router = Router();
// N06 (D81). The collector's daily route: the customers assigned to them with something due or
// overdue on the date. A collector reads only their own; collector.settle reads any (SQL).
router.get(
  '/route',
  authenticate,
  loadRequestContext,
  requirePermission('collection.create'),
  validate({ query: CollectorRouteQuery }),
  asyncHandler(controller.route),
);
export default router;
