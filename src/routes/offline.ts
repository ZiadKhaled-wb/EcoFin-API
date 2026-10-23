// S08 offline cash sales (EC-75). The POS's lease and sync need sale.create and the paired device
// of the request (resolved by loadRequestContext; checked again in SQL); the review, resolution and
// import need offline.resolve; the settings org.settings_manage. A sync is at most 50 sales in 1 MB
// (the app's body limit), an import 500 in 5 MB (its own limit: app.ts leaves this path to it).
import express, { Router } from 'express';
import {
  OfflineImportBody,
  OfflineLeaseBody,
  OfflineResolveBody,
  OfflineSaleIdParams,
  OfflineSaleListQuery,
  OfflineSettingsBody,
  OfflineSyncBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/offline.controller';

/** The import's own body limit (the app's is 1 MB). */
export const OFFLINE_IMPORT_PATH = '/api/offline/import';
const importBody = express.json({ limit: '5mb' });

const router = Router();
router.post(
  '/lease',
  authenticate,
  loadRequestContext,
  requirePermission('sale.create'),
  validate({ body: OfflineLeaseBody }),
  asyncHandler(controller.lease),
);
router.post(
  '/sync',
  authenticate,
  loadRequestContext,
  requirePermission('sale.create'),
  validate({ body: OfflineSyncBody }),
  asyncHandler(controller.sync),
);
router.get(
  '/sales',
  authenticate,
  loadRequestContext,
  requirePermission('offline.resolve'),
  validate({ query: OfflineSaleListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/sales/:id',
  authenticate,
  loadRequestContext,
  requirePermission('offline.resolve'),
  validate({ params: OfflineSaleIdParams }),
  asyncHandler(controller.get),
);
router.post(
  '/sales/:id/resolve',
  authenticate,
  loadRequestContext,
  requirePermission('offline.resolve'),
  validate({ params: OfflineSaleIdParams, body: OfflineResolveBody }),
  asyncHandler(controller.resolve),
);
router.post(
  '/import',
  importBody,
  authenticate,
  loadRequestContext,
  requirePermission('offline.resolve'),
  validate({ body: OfflineImportBody }),
  asyncHandler(controller.importItems),
);
router.get(
  '/settings',
  authenticate,
  loadRequestContext,
  requirePermission('org.settings_manage'),
  validate(),
  asyncHandler(controller.getSettings),
);
router.put(
  '/settings',
  authenticate,
  loadRequestContext,
  requirePermission('org.settings_manage'),
  validate({ body: OfflineSettingsBody }),
  asyncHandler(controller.setSettings),
);
export default router;
