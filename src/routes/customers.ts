import { Router } from 'express';
import {
  CreditCheckQuery,
  CreditExceptionRequestBody,
  CreditLimitBody,
  CustomerContractParams,
  CustomerCreateBody,
  CustomerGuarantorLinkBody,
  CustomerGuarantorParams,
  CustomerGuarantorRelationBody,
  CustomerIdParams,
  CustomerListQuery,
  CustomerStatementQuery,
  CustomerStatusBody,
  CustomerUpdateBody,
  GuarantorRequirementQuery,
} from '@ziadkhaled-wb/contracts';
import { authenticate } from '../middleware/auth';
import { loadRequestContext } from '../middleware/requestContext';
import { authenticatedOnly, requirePermission } from '../middleware/permissions';
import { validate } from '../middleware/validate';
import { asyncHandler } from '../utils/asyncHandler';
import * as controller from '../controllers/customers.controller';
import * as guarantors from '../controllers/guarantors.controller';
import * as credit from '../controllers/credit.controller';
import * as account from '../controllers/customerAccount.controller';
const router = Router();
// Reads: any customer read key (D63 rule 6) and the plan module, both checked in SQL, so they are
// authenticatedOnly() here. The national ID is masked in SQL unless the caller has customer.view_pii.
router.get(
  '/',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ query: CustomerListQuery }),
  asyncHandler(controller.list),
);
router.get(
  '/:id',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams }),
  asyncHandler(controller.get),
);
router.post(
  '/',
  authenticate,
  loadRequestContext,
  requirePermission('customer.create'),
  validate({ body: CustomerCreateBody }),
  asyncHandler(controller.create),
);
router.patch(
  '/:id',
  authenticate,
  loadRequestContext,
  requirePermission('customer.edit'),
  validate({ params: CustomerIdParams, body: CustomerUpdateBody }),
  asyncHandler(controller.update),
);
router.post(
  '/:id/status',
  authenticate,
  loadRequestContext,
  requirePermission('customer.edit'),
  validate({ params: CustomerIdParams, body: CustomerStatusBody }),
  asyncHandler(controller.setStatus),
);
// R04 (D71): a customer's guarantors. Reads: the customer read guard in SQL. Linking: guarantor.manage
// OR customer.create, so authenticatedOnly() and the database function asks for either key; the
// rest need guarantor.manage.
router.get(
  '/:id/guarantors',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams }),
  asyncHandler(guarantors.listForCustomer),
);
router.post(
  '/:id/guarantors',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams, body: CustomerGuarantorLinkBody }),
  asyncHandler(guarantors.link),
);
router.patch(
  '/:id/guarantors/:guarantorId',
  authenticate,
  loadRequestContext,
  requirePermission('guarantor.manage'),
  validate({ params: CustomerGuarantorParams, body: CustomerGuarantorRelationBody }),
  asyncHandler(guarantors.setRelation),
);
router.post(
  '/:id/guarantors/:guarantorId/unlink',
  authenticate,
  loadRequestContext,
  requirePermission('guarantor.manage'),
  validate({ params: CustomerGuarantorParams }),
  asyncHandler(guarantors.unlink),
);
router.get(
  '/:id/guarantor-requirement',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams, query: GuarantorRequirementQuery }),
  asyncHandler(guarantors.requirement),
);
// R03 (D72): a customer's credit. Reads: the customer read guard in SQL. Setting the limit:
// credit.approve. An exception request is sale.create OR credit.approve (no any-of marker, so
// authenticatedOnly() and the database function asks for either key).
router.get(
  '/:id/credit',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams }),
  asyncHandler(credit.profile),
);
router.put(
  '/:id/credit-limit',
  authenticate,
  loadRequestContext,
  requirePermission('credit.approve'),
  validate({ params: CustomerIdParams, body: CreditLimitBody }),
  asyncHandler(credit.setLimit),
);
router.get(
  '/:id/credit-check',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams, query: CreditCheckQuery }),
  asyncHandler(credit.check),
);
router.post(
  '/:id/credit-exceptions',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams, body: CreditExceptionRequestBody }),
  asyncHandler(credit.requestException),
);
// R02 (D74): the customer account, a contract's schedule and the statement. Read only; the
// customer read guard and the plan module are checked in SQL, so authenticatedOnly() here.
router.get(
  '/:id/account',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams }),
  asyncHandler(account.account),
);
router.get(
  '/:id/contracts/:contractId/schedule',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerContractParams }),
  asyncHandler(account.schedule),
);
router.get(
  '/:id/statement',
  authenticate,
  loadRequestContext,
  authenticatedOnly(),
  validate({ params: CustomerIdParams, query: CustomerStatementQuery }),
  asyncHandler(account.statement),
);
export default router;
