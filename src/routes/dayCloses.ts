import { Router } from 'express';
import {
  CloseDayBody,
  DayCloseIdParams,
  DayCloseListQuery,
  DayClosePreviewQuery,
  ReopenDayBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/dayCloses.controller';
const router = Router();
// K04 (D84). Day close and reconciliation. The reads need day.close or cash.view (checked in SQL)
// and work in an expired shop; the branch access, the day lock and every check are in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: DayCloseListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/preview',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: DayClosePreviewQuery }),
  asyncHandler(controller.preview),
);
router.get(
  '/alerts',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  asyncHandler(controller.alerts),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: DayCloseIdParams }),
  asyncHandler(controller.get),
);
// No Idempotency-Key: closing twice is DAY_ALREADY_CLOSED (the client treats it as done).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('day.close'),
  validate({ body: CloseDayBody }),
  asyncHandler(controller.close),
);
router.post(
  '/:id/reopen',
  authenticate,
  loadRequestContext,
  requirePermission('day.reopen'),
  validate({ params: DayCloseIdParams, body: ReopenDayBody }),
  asyncHandler(controller.reopen),
);
export default router;
