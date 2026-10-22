import {
  SaleReturnable,
  SalesReturn,
  SalesReturnListResponse,
  SalesReturnQuote,
  SalesReturnReceiptPrint,
  type SalesReturnCreateBody,
  type SalesReturnListQuery,
  type SalesReturnQuoteBody,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';

// S05 returns and exchanges (D88). Every rule is in SQL (supabase/migrations/20261029090000_s05_returns.sql);
// this layer passes the body, parses the answer with the contract and maps the errors.
function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}

export async function getReturnable(ctx: RequestContext, saleId: string) {
  const { data, error } = await ctx.db.rpc('get_sale_returnable', { p_sale_id: saleId });
  if (error) fail(error);
  return SaleReturnable.parse(data);
}

export async function quote(ctx: RequestContext, body: SalesReturnQuoteBody) {
  const { data, error } = await ctx.db.rpc('quote_sales_return', { p_body: body });
  if (error) fail(error);
  return SalesReturnQuote.parse(data);
}

/** The return, and whether the key answered an earlier one (200 instead of 201). */
export async function post(ctx: RequestContext, body: SalesReturnCreateBody, key: string) {
  const { data, error } = await ctx.db.rpc('post_sales_return', {
    p_body: body,
    p_idempotency_key: key,
  });
  if (error) fail(error);
  return SalesReturn.parse(data);
}

export async function list(ctx: RequestContext, query: SalesReturnListQuery) {
  const { data, error } = await ctx.db.rpc('list_sales_returns', { p_filters: query });
  if (error) fail(error);
  return SalesReturnListResponse.parse(data);
}

export async function get(ctx: RequestContext, id: string) {
  const { data, error } = await ctx.db.rpc('get_sales_return', { p_id: id });
  if (error) fail(error);
  return SalesReturn.parse(data);
}

/** S04 (D68) for a return: logs one print and answers its number (1 = the original). */
export async function recordReceiptPrint(ctx: RequestContext, id: string) {
  const { data, error } = await ctx.db.rpc('record_return_receipt_print', { p_id: id });
  if (error) fail(error);
  return SalesReturnReceiptPrint.parse(data);
}
