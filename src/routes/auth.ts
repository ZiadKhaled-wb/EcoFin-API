// server/src/routes/auth.ts
//
//   public (rate-limited)   login, refresh, forgot-password, reset-password
//   authenticated           me, logout, change-password, select-shop
//
// No route here needs x-org-id: authenticate only checks that it is a UUID when present.
// select-shop takes the shop from its body (D23), so a multi-shop login token works without it.

import { Router } from 'express';
import {
  AuthChangePasswordBody,
  AuthForgotPasswordBody,
  AuthLoginBody,
  AuthRefreshBody,
  AuthResetPasswordBody,
  AuthSelectShopBody,
} from '@ziadkhaled-wb/contracts';
import { asyncHandler } from '../utils/asyncHandler';
import { authenticate } from '../middleware/auth';
import { requestContext } from '../middleware/requestContext';
import { validate } from '../middleware/validate';
import {
  loginLimiter,
  forgotPasswordLimiter,
  refreshLimiter,
  resetPasswordLimiter,
} from '../middleware/rateLimit';
import * as authController from '../controllers/auth.controller';

const router = Router();

// --- Public -----------------------------------------------------------------
// F05: validate() whitelists each request by its contract schema (no schema = nothing accepted).
router.post(
  '/login',
  loginLimiter,
  validate({ body: AuthLoginBody }),
  asyncHandler(authController.login),
);
// D24: /refresh has its own generous per-IP limiter, so silent refreshes from one shop IP can't
// use up the login budget.
router.post(
  '/refresh',
  refreshLimiter,
  validate({ body: AuthRefreshBody }),
  asyncHandler(authController.refresh),
);
router.post(
  '/forgot-password',
  forgotPasswordLimiter,
  validate({ body: AuthForgotPasswordBody }),
  asyncHandler(authController.forgotPassword),
);
router.post(
  '/reset-password',
  resetPasswordLimiter,
  validate({ body: AuthResetPasswordBody }),
  asyncHandler(authController.resetPassword),
);

// --- Authenticated ------------------------------------------------------------
// F05 status gate (requestContext): me and change-password must still work while
// must_change_password is set. logout and select-shop skip the gate, so a user of a closed shop
// can still log out or switch shops.
const contextAllowingPasswordChange = requestContext({ allowMustChangePassword: true });
router.get(
  '/me',
  authenticate,
  contextAllowingPasswordChange,
  validate(),
  asyncHandler(authController.me),
);
router.post('/logout', authenticate, validate(), asyncHandler(authController.logout));
router.post(
  '/select-shop',
  authenticate,
  validate({ body: AuthSelectShopBody }),
  asyncHandler(authController.selectShop),
);
router.post(
  '/change-password',
  authenticate,
  contextAllowingPasswordChange,
  validate({ body: AuthChangePasswordBody }),
  asyncHandler(authController.changePassword),
);

export default router;
