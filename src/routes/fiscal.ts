// T03 ETA submission monitor and corrections (EC-91). fiscal.view reads, fiscal.retry acts; the
// database functions check both again, and the branch of each receipt.
import { Router } from 'express';
import {
  FiscalAssignDeviceBody,
  FiscalDaySummaryQuery,
  FiscalListQuery,
  FiscalRetryManyBody,
  FiscalSubmissionIdParams,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/fiscal.controller';

const router = Router();
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.view'),
  validate({ query: FiscalListQuery }),
  asyncHandler(controller.list),
);
// The fixed paths come before /:id.
router.get(
  '/summary',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.view'),
  validate(),
  asyncHandler(controller.summary),
);
router.get(
  '/day-summary',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.view'),
  validate({ query: FiscalDaySummaryQuery }),
  asyncHandler(controller.daySummary),
);
router.post(
  '/retry-many',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.retry'),
  validate({ body: FiscalRetryManyBody }),
  asyncHandler(controller.retryMany),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.view'),
  validate({ params: FiscalSubmissionIdParams }),
  asyncHandler(controller.details),
);
router.post(
  '/:id/retry',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.retry'),
  validate({ params: FiscalSubmissionIdParams }),
  asyncHandler(controller.retry),
);
router.post(
  '/:id/correct',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.retry'),
  validate({ params: FiscalSubmissionIdParams }),
  asyncHandler(controller.correct),
);
router.post(
  '/:id/assign-device',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.retry'),
  validate({ params: FiscalSubmissionIdParams, body: FiscalAssignDeviceBody }),
  asyncHandler(controller.assignDevice),
);
router.post(
  '/:id/check-now',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.retry'),
  validate({ params: FiscalSubmissionIdParams }),
  asyncHandler(controller.checkNow),
);
export default router;
