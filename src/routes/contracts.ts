import { Router } from 'express';
import {
  CollectionPreviewQuery,
  ContractIdParams,
  ContractListQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/installments.controller';
import * as collections from '../controllers/collections.controller';
const router = Router();
// N03 (D78). The contract search: any customer read key, checked in SQL; the collection keys see
// every branch of the shop, anyone else only their own branches.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: ContractListQuery }),
  asyncHandler(collections.listContracts),
);
// N03 (D78). What is due on a contract and what an amount would pay (no fees: rule 4). Read only;
// an expired shop may look.
router.get(
  '/:id/collection',
  authenticate,
  loadRequestContext,
  requirePermission('collection.create'),
  validate({ params: ContractIdParams, query: CollectionPreviewQuery }),
  asyncHandler(collections.preview),
);
// N02 (D77). A contract: any customer read key and the contract's branch, or any branch for the
// collection keys (N03, D78), checked in SQL (CONTRACT_NOT_FOUND otherwise); an expired shop may read.
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: ContractIdParams }),
  asyncHandler(controller.getContract),
);
export default router;
