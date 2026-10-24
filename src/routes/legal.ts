import { Router } from 'express';
import {
  AddCaseNoteBody,
  AddHearingBody,
  LegalCaseIdParams,
  LegalCaseListQuery,
  LegalHearingParams,
  OpenLegalCaseBody,
  SetLegalCaseStatusBody,
  UpdateHearingBody,
  UpdateLegalCaseBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/legal.controller';
const router = Router();
// L01 + N09 (D92). The legal module: a case opened from a defaulted contract, its status, hearings
// and notes. The module, who may see which case (the owner sees all, a lawyer only their own) and
// the owner-only writes (open a case, assign the lawyer) are checked in SQL. A case never changes
// what a customer owes (Islamic finance rule 4: no fee, no cost). An expired shop may still read.
// The Idempotency-Key header of the open call is read by the controller (IdempotencyKeyHeader).
router.get(
  '/cases',
  authenticate,
  loadRequestContext,
  requirePermission('legal.view'),
  validate({ query: LegalCaseListQuery }),
  asyncHandler(controller.list),
);
router.post(
  '/cases',
  authenticate,
  loadRequestContext,
  requirePermission('legal.manage'),
  validate({ body: OpenLegalCaseBody }),
  asyncHandler(controller.open),
);
router.get(
  '/cases/:id',
  authenticate,
  loadRequestContext,
  requirePermission('legal.view'),
  validate({ params: LegalCaseIdParams }),
  asyncHandler(controller.get),
);
router.patch(
  '/cases/:id',
  authenticate,
  loadRequestContext,
  requirePermission('legal.manage'),
  validate({ params: LegalCaseIdParams, body: UpdateLegalCaseBody }),
  asyncHandler(controller.update),
);
router.post(
  '/cases/:id/status',
  authenticate,
  loadRequestContext,
  requirePermission('legal.manage'),
  validate({ params: LegalCaseIdParams, body: SetLegalCaseStatusBody }),
  asyncHandler(controller.setStatus),
);
router.post(
  '/cases/:id/hearings',
  authenticate,
  loadRequestContext,
  requirePermission('legal.manage'),
  validate({ params: LegalCaseIdParams, body: AddHearingBody }),
  asyncHandler(controller.addHearing),
);
router.patch(
  '/cases/:id/hearings/:hearingId',
  authenticate,
  loadRequestContext,
  requirePermission('legal.manage'),
  validate({ params: LegalHearingParams, body: UpdateHearingBody }),
  asyncHandler(controller.updateHearing),
);
router.post(
  '/cases/:id/notes',
  authenticate,
  loadRequestContext,
  requirePermission('legal.manage'),
  validate({ params: LegalCaseIdParams, body: AddCaseNoteBody }),
  asyncHandler(controller.addNote),
);
// The lawyers to pick from: the owner only (checked in SQL).
router.get(
  '/lawyers',
  authenticate,
  loadRequestContext,
  requirePermission('legal.view'),
  asyncHandler(controller.lawyers),
);
export default router;
