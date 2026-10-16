import { Router } from 'express';
import { ContractIdParams } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/installments.controller';
const router = Router();
// N02 (D77). A contract: any customer read key and the contract's branch, checked in SQL
// (CONTRACT_NOT_FOUND otherwise); an expired shop may read.
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: ContractIdParams }),
  asyncHandler(controller.getContract),
);
export default router;
