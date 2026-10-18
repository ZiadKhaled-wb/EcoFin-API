import { Router } from 'express';
import {
  CollectionPreviewQuery,
  ContractIdParams,
  ContractListQuery,
  ReschedulePreviewBody,
  RescheduleBody,
  SettleBody,
  WriteOffBody,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/installments.controller';
import * as collections from '../controllers/collections.controller';
import * as changes from '../controllers/contractChanges.controller';
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
// N05 (D80). Early settlement: the payoff and the policy's suggested waiver (read only; an expired
// shop may look), then the settlement in the caller's open shift (the Idempotency-Key header is
// read by the controller). The module, the shift and its device are checked in SQL.
router.get(
  '/:id/settlement-quote',
  authenticate,
  loadRequestContext,
  requirePermission('contract.settle_early'),
  validate({ params: ContractIdParams }),
  asyncHandler(changes.settlementQuote),
);
router.post(
  '/:id/settle',
  authenticate,
  loadRequestContext,
  requirePermission('contract.settle_early'),
  validate({ params: ContractIdParams, body: SettleBody }),
  asyncHandler(changes.settle),
);
// N05 (D80). Rescheduling: the new lines (read only), then the new schedule version with a reason.
router.post(
  '/:id/reschedule/preview',
  authenticate,
  loadRequestContext,
  requirePermission('schedule.change'),
  validate({ params: ContractIdParams, body: ReschedulePreviewBody }),
  asyncHandler(changes.previewReschedule),
);
router.post(
  '/:id/reschedule',
  authenticate,
  loadRequestContext,
  requirePermission('schedule.change'),
  validate({ params: ContractIdParams, body: RescheduleBody }),
  asyncHandler(changes.reschedule),
);
// N05 (D80). Write-off: the owner only (checked in SQL).
router.post(
  '/:id/write-off',
  authenticate,
  loadRequestContext,
  requirePermission('contract.write_off'),
  validate({ params: ContractIdParams, body: WriteOffBody }),
  asyncHandler(changes.writeOff),
);
// N05 (D80). A contract's changes and every schedule version: a change key, collection.create or
// report.view, and the contract visibility rule, checked in SQL.
router.get(
  '/:id/changes',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: ContractIdParams }),
  asyncHandler(changes.history),
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
