// server/src/routes/audit.ts  (mounted at /api/audit)
//
//   audit.view   GET /   search the shop's audit log (F07), newest first, paginated
import { Router } from 'express';
import { AuditSearch } from '@ziadkhaled-wb/contracts';
import { asyncHandler } from '../utils/asyncHandler';
import { authenticate } from '../middleware/auth';
import { requirePermission } from '../middleware/permissions';
import { loadRequestContext } from '../middleware/requestContext';
import { validate } from '../middleware/validate';
import * as auditController from '../controllers/audit.controller';

const router = Router();

router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('audit.view'),
  validate({ query: AuditSearch.query }),
  asyncHandler(auditController.search),
);

export default router;
