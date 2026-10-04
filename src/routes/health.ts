// server/src/routes/health.ts
//
// Public route: no authentication and no permission (the only public endpoint besides auth).
import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { publicRoute } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import * as healthController from '../controllers/health.controller';

const router = Router();

router.get('/', publicRoute(), validate(), asyncHandler(healthController.getHealth));

export default router;
