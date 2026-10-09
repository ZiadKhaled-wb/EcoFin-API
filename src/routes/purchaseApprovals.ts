import { Router } from 'express';
import { PurchaseApprovalListQuery } from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/purchases.controller';
const router = Router();
// U06 (D55): purchase invoices waiting for the owner (and decided ones), in the caller's branches.
// Only the owner decides; that is checked when approving or rejecting the invoice.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('purchase.invoice_approve'),
  validate({ query: PurchaseApprovalListQuery }),
  asyncHandler(controller.approvals),
);
export default router;
