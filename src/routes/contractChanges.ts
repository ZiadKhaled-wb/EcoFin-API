import { Router } from 'express';
import { ContractChangeListQuery } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/contractChanges.controller';
const router = Router();
// N05 (D80). The shop's early settlements, reschedules and write-offs, newest first, with totals
// by kind: report.financial or one of the three change keys, checked in SQL. An expired shop may
// read.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ContractChangeListQuery }),
  asyncHandler(controller.list),
);
export default router;
