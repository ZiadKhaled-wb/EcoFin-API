import { Router } from 'express';
import { DashboardQuery } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/dashboard.controller';
const router = Router();
// D01 (D87). The owner dashboard. A signed-in employee of the shop reads it (also in an expired
// shop); each tile is checked in SQL against the permission its detail page needs and is null
// without it, so an employee with no tile key gets an answer, not a denial.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: DashboardQuery }),
  asyncHandler(controller.get),
);
export default router;
