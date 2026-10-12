import {
  DiscountApproval,
  DiscountApprovalList,
  DiscountApprovalRequested,
  DiscountApprovalResult,
  Sale,
  SalePaymentAccountList,
  SaleQuote,
  type DiscountApprovalDecideBody,
  type DiscountApprovalListQuery,
  type DiscountApprovalRequestBody,
  type SaleCreateBody,
  type SaleQuoteBody,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'sale database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/**
 * S01: prices a cart for the caller's open shift (list prices, or another price with
 * price.override; the shop's VAT mode). With payment lines (S02) it also answers what is paid, what
 * remains and the change. Nothing is written or reserved.
 */
export async function quoteSale(ctx: RequestContext, body: SaleQuoteBody): Promise<SaleQuote> {
  const { data, error } = await ctx.db.rpc('quote_sale', {
    p_lines: body.lines,
    ...(body.customer_id ? { p_customer_id: body.customer_id } : {}),
    ...(body.payments ? { p_payments: body.payments } : {}),
    ...(body.sale_discount ? { p_sale_discount: body.sale_discount } : {}),
  });
  if (error) fail(error);
  return SaleQuote.parse(data);
}

/**
 * S01 (D62) + S02 (D64): a sale in the caller's open shift, in one database transaction, paid by
 * the given payment lines (cash in full without them). The same idempotency key again returns the
 * first sale and sells nothing. A total other than `expected_total` answers PRICE_CHANGED with
 * both totals; lines that don't add up to the total answer PAYMENT_TOTAL_MISMATCH.
 * S03 (D65): lines and the sale may carry a discount (the total is after it, the payments must add
 * up to it). Above the caller's cap the sale answers DISCOUNT_ABOVE_CAP unless the caller has
 * discount.above_cap or sends the id of an approved request (APPROVAL_INVALID when it doesn't fit).
 */
export async function postSale(
  ctx: RequestContext,
  body: SaleCreateBody,
  idempotencyKey: string,
): Promise<Sale> {
  const { data, error } = await ctx.db.rpc('post_sale', {
    p_lines: body.lines,
    p_expected_total: body.expected_total,
    p_idempotency_key: idempotencyKey,
    ...(body.customer_id ? { p_customer_id: body.customer_id } : {}),
    ...(body.payments ? { p_payments: body.payments } : {}),
    ...(body.sale_discount ? { p_sale_discount: body.sale_discount } : {}),
    ...(body.discount_reason ? { p_discount_reason: body.discount_reason } : {}),
    ...(body.discount_approval_id ? { p_discount_approval_id: body.discount_approval_id } : {}),
  });
  if (error) fail(error);
  return Sale.parse(data);
}

/** The caller's own sale, or any sale of their branches with report.view or cash.view. */
export async function getSale(ctx: RequestContext, id: string): Promise<Sale> {
  const { data, error } = await ctx.db.rpc('get_sale', { p_id: id });
  if (error) fail(error);
  return Sale.parse(data);
}

/** S02: the active banks the caller's open shift can take a transfer into, by name only. */
export async function listPaymentAccounts(ctx: RequestContext): Promise<SalePaymentAccountList> {
  const { data, error } = await ctx.db.rpc('list_sale_payment_accounts');
  if (error) fail(error);
  return SalePaymentAccountList.parse(data);
}

/**
 * S03 (D65): asks a manager to approve exactly this cart (the server prices it and keeps its
 * fingerprint). APPROVAL_NOT_NEEDED when no line is above the caller's cap.
 */
export async function requestDiscountApproval(
  ctx: RequestContext,
  body: DiscountApprovalRequestBody,
): Promise<DiscountApprovalRequested> {
  const { data, error } = await ctx.db.rpc('request_discount_approval', {
    p_branch_id: body.branch_id,
    p_lines: body.lines,
    p_sale_discount: body.sale_discount ?? null,
    p_reason: body.reason,
  });
  if (error) fail(error);
  return DiscountApprovalRequested.parse(data);
}

/** The requester's own approval, or any of their branches with discount.above_cap. */
export async function getDiscountApproval(
  ctx: RequestContext,
  id: string,
): Promise<DiscountApproval> {
  const { data, error } = await ctx.db.rpc('get_discount_approval', { p_approval_id: id });
  if (error) fail(error);
  return DiscountApproval.parse(data);
}

/** The requester takes a pending request back. */
export async function cancelDiscountApproval(
  ctx: RequestContext,
  id: string,
): Promise<DiscountApprovalResult> {
  const { data, error } = await ctx.db.rpc('cancel_discount_approval', { p_approval_id: id });
  if (error) fail(error);
  return DiscountApprovalResult.parse(data);
}

/** discount.above_cap: the requests of the caller's branches, waiting ones by default. */
export async function listDiscountApprovals(
  ctx: RequestContext,
  query: DiscountApprovalListQuery,
): Promise<DiscountApprovalList> {
  const { data, error } = await ctx.db.rpc('list_discount_approvals', { p_status: query.status });
  if (error) fail(error);
  return DiscountApprovalList.parse(data);
}

/** discount.above_cap, not the requester, with access to the request's branch. */
export async function decideDiscountApproval(
  ctx: RequestContext,
  id: string,
  body: DiscountApprovalDecideBody,
): Promise<DiscountApprovalResult> {
  const { data, error } = await ctx.db.rpc('decide_discount_approval', {
    p_approval_id: id,
    p_approve: body.approve,
    ...(body.note ? { p_note: body.note } : {}),
  });
  if (error) fail(error);
  return DiscountApprovalResult.parse(data);
}
