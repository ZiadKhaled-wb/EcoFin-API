import { Router } from 'express';
import {
  CollectionBody,
  CollectionIdParams,
  CollectionReverseBody,
  FieldCollectionBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/collections.controller';
import * as wallets from '../controllers/wallets.controller';
const router = Router();
// N03 (D78). A collection on one or several contracts of one customer, split over cash and bank
// transfers, in the caller's open shift. The module, the shift and its device are checked in SQL.
// The Idempotency-Key header is read by the controller (IdempotencyKeyHeader).
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('collection.create'),
  validate({ body: CollectionBody }),
  asyncHandler(controller.create),
);
// N06 (D81). A collection taken in the field: no shift, the cash goes into the caller's own wallet.
// The customer must be assigned to the caller unless the caller holds collector.settle (SQL).
router.post(
  '/field',
  authenticate,
  loadRequestContext,
  requirePermission('collection.create'),
  validate({ body: FieldCollectionBody }),
  asyncHandler(wallets.createFieldCollection),
);
// The receipt: collection.create or collection.reverse, checked in SQL (any branch).
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CollectionIdParams }),
  asyncHandler(controller.get),
);
// The receipt print log (S04's pattern): either collection key, checked in SQL.
router.post(
  '/:id/prints',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CollectionIdParams }),
  asyncHandler(controller.print),
);
// Same business day, the latest collection of its contracts, the collection's shift still open.
router.post(
  '/:id/reverse',
  authenticate,
  loadRequestContext,
  requirePermission('collection.reverse'),
  validate({ params: CollectionIdParams, body: CollectionReverseBody }),
  asyncHandler(controller.reverse),
);
export default router;
