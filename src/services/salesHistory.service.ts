import {
  SaleHistoryDetails,
  SalesHistoryResponse,
  SaleVoidResponse,
  type SalesHistoryQuery,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
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
/** S07 mapper preserves all S01/S02/S03 response fields alongside computed history. */
export function mapSaleHistoryDetails(data: unknown) {
  return SaleHistoryDetails.parse(data);
}
export async function getSaleDetails(ctx: RequestContext, id: string) {
  const { data, error } = await ctx.db.rpc('get_sale_details', { p_sale_id: id });
  if (error) fail(error);
  return mapSaleHistoryDetails(data);
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
