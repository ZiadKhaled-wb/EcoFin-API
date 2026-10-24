import { Router } from 'express';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { asyncHandler } from '../utils/asyncHandler';
import * as c from '../controllers/salesOrders.controller';
// S10. loadRequestContext resolves the POS device (x-device-token), so a deposit and a cancel's
// cash refund reach app.require_shift_device with this device, as the POS sale route does.
// Create, deposit and cancel read the Idempotency-Key header. The order made from a quotation
// is POST /api/quotations/:id/order (routes/quotations.ts).
const router = Router();
router.use(authenticate, loadRequestContext);
router.get('/', requirePermission('order.manage'), asyncHandler(c.list));
router.get('/:id', requirePermission('order.manage'), asyncHandler(c.get));
router.post('/', requirePermission('order.manage'), asyncHandler(c.create));
router.post('/:id/deposits', requirePermission('order.manage'), asyncHandler(c.deposit));
router.post(
  '/:id/lines/:lineId/reserve',
  requirePermission('order.manage'),
  asyncHandler(c.reserve),
);
router.post(
  '/:id/lines/:lineId/link-po',
  requirePermission('order.manage'),
  asyncHandler(c.linkPo),
);
router.post('/:id/cancel', requirePermission('order.cancel'), asyncHandler(c.cancel));
export default router;
