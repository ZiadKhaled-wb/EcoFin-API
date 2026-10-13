import {
  SaleHistoryDetails,
  SaleReceiptPrint,
  SalesHistoryResponse,
  SaleVoidResponse,
  type SalesHistoryQuery,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { withEta } from './eta.service';
import { mapDbError, ServerError } from '../utils/errors';

function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}
export async function searchSales(ctx: RequestContext, query: SalesHistoryQuery) {
  const args = {
    ...(query.q ? { p_query: query.q } : {}),
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.customer_id ? { p_customer_id: query.customer_id } : {}),
    ...(query.cashier_id ? { p_cashier_id: query.cashier_id } : {}),
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    ...(query.status ? { p_status: query.status } : {}),
    p_limit: query.page_size,
    p_offset: (query.page - 1) * query.page_size,
  };
  const result = await ctx.db.rpc('search_sales', args);
  if (result.error) fail(result.error);
  let total = result.data?.[0]?.total_count ?? 0;
  if (!result.data?.length && query.page > 1) {
    const first = await ctx.db.rpc('search_sales', { ...args, p_limit: 1, p_offset: 0 });
    if (first.error) fail(first.error);
    total = first.data?.[0]?.total_count ?? 0;
  }
  return SalesHistoryResponse.parse({ items: result.data ?? [], total });
}
/** Preserves the sale fields alongside computed S07 history. */
export function mapSaleHistoryDetails(data: unknown) {
  return SaleHistoryDetails.parse(data);
}
export async function getSaleDetails(ctx: RequestContext, id: string) {
  const { data, error } = await ctx.db.rpc('get_sale_details', { p_sale_id: id });
  if (error) fail(error);
  const details = mapSaleHistoryDetails(data);
  const { eta } = await withEta(ctx, details);
  return { ...details, eta };
}
export async function voidSale(ctx: RequestContext, id: string, reason: string, key: string) {
  const { data, error } = await ctx.db.rpc('void_sale', {
    p_sale_id: id,
    p_reason: reason,
    p_idempotency_key: key,
  });
  if (error) fail(error);
  return SaleVoidResponse.parse(data);
}
/** S04 (D68): logs one print of the sale's receipt and answers its number (1 = the original). */
export async function recordReceiptPrint(ctx: RequestContext, id: string) {
  const { data, error } = await ctx.db.rpc('record_sale_receipt_print', { p_sale_id: id });
  if (error) fail(error);
  return SaleReceiptPrint.parse(data);
}
