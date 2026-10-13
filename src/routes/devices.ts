// The POS devices of a shop.
// T02 (D67): each one's registration with the ETA. The pre-shared key is write-only
// (`has_preshared_key` in answers, never the key).
// O03 (D68): creating, renaming, moving and turning devices off, and pairing a computer with
// one. A pairing code and a device token are each answered once; only their hashes are stored.
import { Router } from 'express';
import {
  DeviceActiveBody,
  DeviceCreateBody,
  DeviceEtaBody,
  DeviceIdParams,
  DevicePairBody,
  DeviceUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { devicePairLimiter } from '../middleware/rateLimit';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as etaController from '../controllers/eta.controller';
import * as controller from '../controllers/devices.controller';

const router = Router();
// device.manage (the devices screen) or org.settings_manage (the ETA settings' device picker):
// checked in SQL.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate(),
  asyncHandler(etaController.listDevices),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('device.manage'),
  validate({ body: DeviceCreateBody }),
  asyncHandler(controller.createDevice),
);
// The device of this computer, as loadRequestContext resolved it from x-device-token.
router.get(
  '/current',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate(),
  asyncHandler(controller.currentDevice),
);
// shift.operate or device.manage: checked in SQL. Five attempts a minute for each user, counted
// before the code is looked at.
router.post(
  '/pair',
  authenticate,
  devicePairLimiter,
  loadRequestContext,
  authenticatedOnly(),
  validate({ body: DevicePairBody }),
  asyncHandler(controller.pairDevice),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('device.manage'),
  validate({ params: DeviceIdParams, body: DeviceUpdateBody }),
  asyncHandler(controller.updateDevice),
);
router.post(
  '/:id/active',
  authenticate,
  loadRequestContext,
  requirePermission('device.manage'),
  validate({ params: DeviceIdParams, body: DeviceActiveBody }),
  asyncHandler(controller.setDeviceActive),
);
router.post(
  '/:id/pairing-code',
  authenticate,
  loadRequestContext,
  requirePermission('device.manage'),
  validate({ params: DeviceIdParams }),
  asyncHandler(controller.createPairingCode),
);
router.post(
  '/:id/unpair',
  authenticate,
  loadRequestContext,
  requirePermission('device.manage'),
  validate({ params: DeviceIdParams }),
  asyncHandler(controller.unpairDevice),
);
router.put(
  '/:id/eta',
  authenticate,
  loadRequestContext,
  requirePermission('device.manage'),
  validate({ params: DeviceIdParams, body: DeviceEtaBody }),
  asyncHandler(etaController.setDeviceEta),
);
export default router;
