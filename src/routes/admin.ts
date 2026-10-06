import { Router } from 'express';
import {
  AdminCreateShopBody,
  AdminShopsQuery,
  AdminShopId,
  AdminShopStatusBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { authenticatedOnly } from '../middleware/permissions';
import { ignoreShopContext, requireSuperAdmin } from '../middleware/superAdmin';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as admin from '../controllers/admin.controller';
import * as subscription from '../controllers/subscription.controller';
import {
  SubscriptionPlanBody,
  SubscriptionDatesBody,
  SubscriptionPaymentBody,
} from '@ziadkhaled-wb/contracts';
const router = Router();
const guards = [ignoreShopContext, authenticate, authenticatedOnly(), requireSuperAdmin];
router.get('/plans', ...guards, validate(), asyncHandler(admin.plans));
router.get('/shops', ...guards, validate({ query: AdminShopsQuery }), asyncHandler(admin.shops));
router.post(
  '/shops',
  ...guards,
  validate({ body: AdminCreateShopBody }),
  asyncHandler(admin.create),
);
router.post(
  '/shops/:id/status',
  ...guards,
  validate({ params: AdminShopId, body: AdminShopStatusBody }),
  asyncHandler(admin.status),
);
router.post(
  '/shops/:id/owner-invite',
  ...guards,
  validate({ params: AdminShopId }),
  asyncHandler(admin.resend),
);
router.get(
  '/shops/:id/subscription',
  ...guards,
  validate({ params: AdminShopId }),
  asyncHandler(subscription.adminStatus),
);
router.post(
  '/shops/:id/plan',
  ...guards,
  validate({ params: AdminShopId, body: SubscriptionPlanBody }),
  asyncHandler(subscription.plan),
);
router.post(
  '/shops/:id/subscription-dates',
  ...guards,
  validate({ params: AdminShopId, body: SubscriptionDatesBody }),
  asyncHandler(subscription.dates),
);
router.post(
  '/shops/:id/payments',
  ...guards,
  validate({ params: AdminShopId, body: SubscriptionPaymentBody }),
  asyncHandler(subscription.payment),
);
export default router;
