import { Router } from 'express';
import {
  MigrationBatchParams,
  MigrationReportQuery,
  MigrationSignOffBody,
  ReverseMigrationBatchBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/migration.controller';
const router = Router();
// M02 (D85). The reads need import.data or report.financial (checked in SQL) and work in an
// expired shop; the writes need import.data.
router.get(
  '/report',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: MigrationReportQuery }),
  asyncHandler(controller.report),
);
router.get(
  '/sign-offs',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  asyncHandler(controller.listSignOffs),
);
router.post(
  '/sign-offs',
  authenticate,
  loadRequestContext,
  requirePermission('import.data'),
  validate({ body: MigrationSignOffBody }),
  asyncHandler(controller.signOff),
);
router.post(
  '/batches/:id/reverse',
  authenticate,
  loadRequestContext,
  requirePermission('import.data'),
  validate({ params: MigrationBatchParams, body: ReverseMigrationBatchBody }),
  asyncHandler(controller.reverse),
);
export default router;
