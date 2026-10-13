// T02 (D67): the POS devices and each one's registration with the ETA. The pre-shared key is
// write-only (`has_preshared_key` in answers, never the key).
import { Router } from 'express';
import { DeviceEtaBody, DeviceIdParams } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/eta.controller';

const router = Router();
// device.manage (the devices screen) or org.settings_manage (the ETA settings' device picker):
// checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate(),
  asyncHandler(controller.listDevices),
);
router.put(
  '/:id/eta',
  authenticate,
  loadRequestContext,
  requirePermission('device.manage'),
  validate({ params: DeviceIdParams, body: DeviceEtaBody }),
  asyncHandler(controller.setDeviceEta),
);
export default router;
