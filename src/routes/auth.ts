// server/src/routes/auth.ts
//
// Chain reference for the auth routes:
//
//   public              login, check-license, activate-workspace, forgot-password
//   authenticated       change-password (bypasses requirePasswordChanged)
//   owner + password    reset-owner-password
//   any authenticated   me, logout

import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import {
    authenticate,
    attachEmployee,
    attachSuperAdmin,
    requireTenant,
    requirePasswordChanged,
    isOwner,
} from '../middleware/auth';
import {
    loginLimiter,
    licenseLimiter,
    forgotPasswordLimiter,
} from '../middleware/rateLimit';
import * as authController from '../controllers/auth.controller';

const router = Router();

// --- Public (rate-limited) --------------------------------------------------

router.post('/login', loginLimiter, asyncHandler(authController.login));
router.post('/check-license', licenseLimiter, asyncHandler(authController.checkLicense));
router.post('/activate-workspace', licenseLimiter, asyncHandler(authController.activateWorkspace));
router.post('/forgot-password', forgotPasswordLimiter, asyncHandler(authController.forgotPassword));

// --- Authenticated ----------------------------------------------------------

// Deliberately does NOT include requirePasswordChanged: this is the ONLY
// endpoint (besides logout) that a temp-password user must be able to reach.
router.post(
    '/change-password',
    authenticate,
    attachEmployee,
    requireTenant,
    asyncHandler(authController.changePassword),
);

router.post(
    '/reset-owner-password',
    authenticate,
    attachEmployee,
    requirePasswordChanged,
    isOwner,
    asyncHandler(authController.resetOwnerPassword),
);

router.get(
    '/me',
    authenticate,
    attachEmployee,
    attachSuperAdmin,
    requirePasswordChanged,
    asyncHandler(authController.getCurrentUser),
);

router.post(
    '/logout',
    authenticate,
    attachEmployee,
    asyncHandler(authController.logout),
);

export default router;