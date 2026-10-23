import { Router } from 'express';
import { ReceivablesQuery, SalesReportQuery } from '@ziadkhaled-wb/contracts';
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
// D03 (D91). Receivables aging: the function checks report.financial in SQL the same way.
router.get(
  '/receivables',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ReceivablesQuery }),
  asyncHandler(controller.receivables),
);
export default router;
