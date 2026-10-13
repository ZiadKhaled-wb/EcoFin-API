// T02 ETA e-receipts (D67): the shop's ETA connection and the manual retry of a receipt. The
// submissions monitor is T03. Secrets are write-only: no answer here carries one.
import { Router } from 'express';
import { EtaSettingsBody, EtaTestBody, FiscalSubmissionIdParams } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/eta.controller';

const router = Router();
router.get(
  '/settings',
  authenticate,
  loadRequestContext,
  requirePermission('org.settings_manage'),
  validate(),
  asyncHandler(controller.getSettings),
);
router.put(
  '/settings',
  authenticate,
  loadRequestContext,
  requirePermission('org.settings_manage'),
  validate({ body: EtaSettingsBody }),
  asyncHandler(controller.setSettings),
);
// Logs a POS in at the ETA with the stored credentials. Answers ok or the ETA's error code only.
router.post(
  '/settings/test',
  authenticate,
  loadRequestContext,
  requirePermission('org.settings_manage'),
  validate({ body: EtaTestBody }),
  asyncHandler(controller.testConnection),
);
router.post(
  '/submissions/:id/retry',
  authenticate,
  loadRequestContext,
  requirePermission('fiscal.retry'),
  validate({ params: FiscalSubmissionIdParams }),
  asyncHandler(controller.retrySubmission),
);
export default router;
