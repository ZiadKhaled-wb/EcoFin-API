import { Router } from 'express';
import {
  CreateImportBody,
  ImportIdParams,
  ImportKindParams,
  ImportListQuery,
  ImportTemplateQuery,
  InspectImportBody,
  RunImportBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/imports.controller';
const router = Router();
// M01 (D83). Static paths first: /templates/:kind and /inspect must not be read as an id.
router.get(
  '/templates/:kind',
  authenticate,
  loadRequestContext,
  requirePermission('import.data'),
  validate({ params: ImportKindParams, query: ImportTemplateQuery }),
  asyncHandler(controller.template),
);
router.post(
  '/inspect',
  authenticate,
  loadRequestContext,
  requirePermission('import.data'),
  validate({ body: InspectImportBody }),
  asyncHandler(controller.inspect),
);
// Reads: import.data or export.data, checked in SQL (an expired shop can still read its history).
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ImportListQuery }),
  asyncHandler(controller.list),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('import.data'),
  validate({ body: CreateImportBody }),
  asyncHandler(controller.create),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: ImportIdParams }),
  asyncHandler(controller.get),
);
router.post(
  '/:id/run',
  authenticate,
  loadRequestContext,
  requirePermission('import.data'),
  validate({ params: ImportIdParams, body: RunImportBody }),
  asyncHandler(controller.run),
);
router.post(
  '/:id/cancel',
  authenticate,
  loadRequestContext,
  requirePermission('import.data'),
  validate({ params: ImportIdParams }),
  asyncHandler(controller.cancel),
);
export default router;
