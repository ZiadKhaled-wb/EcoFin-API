import { Router } from 'express';
import {
  DismissReferralBody,
  HandleWarningBody,
  LegalReferralListQuery,
  OverdueActionIdParams,
  OverdueListQuery,
  OverdueWarningListQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/overdue.controller';
const router = Router();
// N04 (D79). Overdue tracking, no late fees (Islamic finance rule 4). overdue.view sees every
// branch of the shop; the module and the owner-only writes are checked in SQL. An expired shop may
// still read.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('overdue.view'),
  validate({ query: OverdueListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/warnings',
  authenticate,
  loadRequestContext,
  requirePermission('overdue.view'),
  validate({ query: OverdueWarningListQuery }),
  asyncHandler(controller.listWarnings),
);
router.post(
  '/warnings/:id/handle',
  authenticate,
  loadRequestContext,
  requirePermission('overdue.handle'),
  validate({ params: OverdueActionIdParams, body: HandleWarningBody }),
  asyncHandler(controller.handleWarning),
);
router.get(
  '/legal-referrals',
  authenticate,
  loadRequestContext,
  requirePermission('overdue.view'),
  validate({ query: LegalReferralListQuery }),
  asyncHandler(controller.listReferrals),
);
// The owner only (checked in SQL).
router.post(
  '/legal-referrals/:id/dismiss',
  authenticate,
  loadRequestContext,
  requirePermission('overdue.view'),
  validate({ params: OverdueActionIdParams, body: DismissReferralBody }),
  asyncHandler(controller.dismissReferral),
);
// The owner runs the nightly check by hand (checked in SQL); safe to repeat.
router.post(
  '/run',
  authenticate,
  loadRequestContext,
  requirePermission('overdue.view'),
  asyncHandler(controller.run),
);
export default router;
