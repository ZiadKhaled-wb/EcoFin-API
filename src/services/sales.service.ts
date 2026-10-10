import {
  Sale,
  SalePaymentAccountList,
  SaleQuote,
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
  });
  if (error) fail(error);
  return SaleQuote.parse(data);
}

/**
 * S01 (D62) + S02 (D64): a sale in the caller's open shift, in one database transaction, paid by
 * the given payment lines (cash in full without them). The same idempotency key again returns the
 * first sale and sells nothing. A total other than `expected_total` answers PRICE_CHANGED with
 * both totals; lines that don't add up to the total answer PAYMENT_TOTAL_MISMATCH.
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
