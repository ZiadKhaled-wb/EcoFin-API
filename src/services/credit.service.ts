import {
  CreditCheck,
  CreditException,
  CreditExceptionList,
  CreditProfile,
  type CreditCheckQuery,
  type CreditExceptionDecideBody,
  type CreditExceptionListQuery,
  type CreditExceptionRequestBody,
  type CreditLimitBody,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// R03 (D72). The database decides everything: who may read or set a limit, what the exposure and
// the score are, whether an exception is needed and who may decide it. Nothing here computes
// money or credit; the rows are only checked against the contract on the way out.

function fail(error: unknown): never {
  // The message and the Postgres code only: a request body is never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'credit database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

export async function getCreditProfile(
  ctx: RequestContext,
  customerId: string,
): Promise<CreditProfile> {
  const { data, error } = await ctx.db.rpc('get_customer_credit_profile', {
    p_customer_id: customerId,
  });
  if (error) fail(error);
  return CreditProfile.parse(data);
}

/** `credit.approve`. A reason is needed only when the limit goes up (CREDIT_REASON_REQUIRED). */
export async function setCreditLimit(
  ctx: RequestContext,
  customerId: string,
  body: CreditLimitBody,
): Promise<CreditProfile> {
  const { data, error } = await ctx.db.rpc('set_customer_credit_limit', {
    p_customer_id: customerId,
    p_limit: body.credit_limit,
    ...(body.reason ? { p_reason: body.reason } : {}),
  });
  if (error) fail(error);
  return CreditProfile.parse(data);
}

/** Would an installment sale of this financed amount pass now? Never raises for the credit reasons. */
export async function getCreditCheck(
  ctx: RequestContext,
  customerId: string,
  query: CreditCheckQuery,
): Promise<CreditCheck> {
  const { data, error } = await ctx.db.rpc('get_customer_credit_check', {
    p_customer_id: customerId,
    p_financed_amount: query.financed_amount,
  });
  if (error) fail(error);
  return CreditCheck.parse(data);
}

/** `sale.create` or `credit.approve` (checked in SQL). */
export async function requestCreditException(
  ctx: RequestContext,
  customerId: string,
  body: CreditExceptionRequestBody,
): Promise<CreditException> {
  const { data, error } = await ctx.db.rpc('request_credit_exception', {
    p_customer_id: customerId,
    p_financed_amount: body.financed_amount,
    p_reason: body.reason,
  });
  if (error) fail(error);
  return CreditException.parse(data);
}

export async function listCreditExceptions(
  ctx: RequestContext,
  query: CreditExceptionListQuery,
): Promise<CreditExceptionList> {
  const { data, error } = await ctx.db.rpc('list_credit_exceptions', { p_status: query.status });
  if (error) fail(error);
  return CreditExceptionList.parse(data);
}

export async function getCreditException(
  ctx: RequestContext,
  id: string,
): Promise<CreditException> {
  const { data, error } = await ctx.db.rpc('get_credit_exception', { p_id: id });
  if (error) fail(error);
  return CreditException.parse(data);
}

/** `credit.approve`. Rejecting needs a note; the requester can't decide, except the owner. */
export async function decideCreditException(
  ctx: RequestContext,
  id: string,
  body: CreditExceptionDecideBody,
): Promise<CreditException> {
  const { data, error } = await ctx.db.rpc('decide_credit_exception', {
    p_approval_id: id,
    p_approve: body.approve,
    ...(body.note ? { p_note: body.note } : {}),
  });
  if (error) fail(error);
  return CreditException.parse(data);
}

/** Only the requester, while the request is pending. */
export async function cancelCreditException(
  ctx: RequestContext,
  id: string,
): Promise<CreditException> {
  const { data, error } = await ctx.db.rpc('cancel_credit_exception', { p_approval_id: id });
  if (error) fail(error);
  return CreditException.parse(data);
}
