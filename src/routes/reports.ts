import { Router } from 'express';
import { SalesReportQuery } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/reports.controller';
const router = Router();
// D02 (D89). Reports of the owner and the accountant (later report slices add their routes here).
// A signed-in employee of the shop reaches the function, which checks report.view in SQL with
// app.has_permission (so an expired shop can still read) and report.financial for the cost columns.
router.get(
  '/sales',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: SalesReportQuery }),
  asyncHandler(controller.sales),
);
export default router;
