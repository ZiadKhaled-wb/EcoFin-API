// S08 (D1): GET /api/health, the POS's connectivity check while it is offline. Public: no
// authentication, no permission and no database (F08's /health checks the database).
import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { publicRoute } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import * as controller from '../controllers/offline.controller';

const router = Router();

router.get('/', publicRoute(), validate(), asyncHandler(controller.health));

export default router;
