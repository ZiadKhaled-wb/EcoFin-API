import { Router } from 'express';
import { InstallmentPreviewBody, InstallmentSaleBody } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/installments.controller';
const router = Router();
// N01 (D76). The preview reads only: the terms of an installment sale under the shop's current
// policy, plus the customer's credit, guarantor and survey requirements. The installments module
// and switch are checked in SQL; an expired shop may still preview.
router.post(
  '/preview',
  authenticate,
  loadRequestContext,
  requirePermission('installment.create'),
  validate({ body: InstallmentPreviewBody }),
  asyncHandler(controller.preview),
);
// N02 (D77). The installment sale: sale, down payment and contract in one transaction. sale.create,
// the modules, the switch, the shift and its device are checked in SQL. The Idempotency-Key header
// is read by the controller (IdempotencyKeyHeader).
router.post(
  '/sales',
  authenticate,
  loadRequestContext,
  requirePermission('installment.create'),
  validate({ body: InstallmentSaleBody }),
  asyncHandler(controller.createSale),
);
export default router;
