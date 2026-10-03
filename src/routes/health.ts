// server/src/routes/health.ts
//
// Public route: no authentication and no permission (the only public endpoint besides auth).
import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import * as healthController from '../controllers/health.controller';

const router = Router();

router.get('/', asyncHandler(healthController.getHealth));

export default router;
