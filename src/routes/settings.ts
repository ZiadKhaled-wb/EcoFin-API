// P03 shop settings. Replaces FinTech-Pro's GET/PUT /settings (role names, service role) with
// permission markers; PUT becomes a partial PATCH and the installment policy gets its own
// versioned endpoints. FinTech-Pro's POST /settings/reset is dropped: defaults come from P01.
import { Router } from 'express';
import { InstallmentPolicyBody, ShopSettingsUpdateBody } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/settings.controller';

const router = Router();
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate(),
  asyncHandler(controller.get),
);
router.patch(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('org.settings_manage'),
  validate({ body: ShopSettingsUpdateBody }),
  asyncHandler(controller.update),
);
router.get(
  '/installment-policies',
  authenticate,
  loadRequestContext,
  requirePermission('org.settings_manage'),
  validate(),
  asyncHandler(controller.listPolicies),
);
router.post(
  '/installment-policies',
  authenticate,
  loadRequestContext,
  requirePermission('org.settings_manage'),
  validate({ body: InstallmentPolicyBody }),
  asyncHandler(controller.publishPolicy),
);
export default router;
