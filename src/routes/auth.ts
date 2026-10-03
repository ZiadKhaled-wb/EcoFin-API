// server/src/routes/auth.ts
//
//   public (rate-limited)   login, refresh, forgot-password, reset-password
//   authenticated           me, logout, change-password, select-shop
//
// No route here needs x-org-id: authenticate only checks that it is a UUID when present.
// select-shop takes the shop from its body (D23), so a multi-shop login token works without it.

import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { authenticate } from '../middleware/auth';
import { loginLimiter, forgotPasswordLimiter } from '../middleware/rateLimit';
import * as authController from '../controllers/auth.controller';

const router = Router();

// --- Public -----------------------------------------------------------------
router.post('/login', loginLimiter, asyncHandler(authController.login));
// Refresh tokens are long random values that Supabase rotates; Supabase Auth rate-limits
// refreshes itself. Not on loginLimiter, so silent refreshes from several devices behind one
// shop IP can't lock people out of logging in.
router.post('/refresh', asyncHandler(authController.refresh));
router.post('/forgot-password', forgotPasswordLimiter, asyncHandler(authController.forgotPassword));
router.post('/reset-password', forgotPasswordLimiter, asyncHandler(authController.resetPassword));

// --- Authenticated ------------------------------------------------------------
router.get('/me', authenticate, asyncHandler(authController.me));
router.post('/logout', authenticate, asyncHandler(authController.logout));
router.post('/select-shop', authenticate, asyncHandler(authController.selectShop));
router.post('/change-password', authenticate, asyncHandler(authController.changePassword));

export default router;
