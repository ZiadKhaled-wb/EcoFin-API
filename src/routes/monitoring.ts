// server/src/routes/monitoring.ts  (mounted at /api/monitoring)
//
//   org.settings_manage   POST /test-error   raise a deliberate server error (Q02, D35)
//
// Proves error tracking end to end: the call returns 500 with a request id, and the same id is on
// the event in Sentry. Writes nothing. Owner-level permission, so it can't be used to flood the
// tracker from a cashier account; the global rate limit applies too.
import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { authenticate } from '../middleware/auth';
import { requirePermission } from '../middleware/permissions';
import { loadRequestContext } from '../middleware/requestContext';
import { validate } from '../middleware/validate';
import * as monitoringController from '../controllers/monitoring.controller';

const router = Router();

router.post(
  '/test-error',
  authenticate,
  loadRequestContext,
  requirePermission('org.settings_manage'),
  validate(),
  asyncHandler(monitoringController.testError),
);

export default router;
