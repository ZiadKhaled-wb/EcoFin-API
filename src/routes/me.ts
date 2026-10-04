// server/src/routes/me.ts  (mounted at /api/me)
//
//   authenticated   GET /permissions   the caller's effective permissions and branches (F06)
import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { authenticate } from '../middleware/auth';
import { authenticatedOnly } from '../middleware/permissions';
import { loadRequestContext } from '../middleware/requestContext';
import { validate } from '../middleware/validate';
import * as meController from '../controllers/me.controller';

const router = Router();

router.get(
  '/permissions',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate(),
  asyncHandler(meController.permissions),
);

export default router;
