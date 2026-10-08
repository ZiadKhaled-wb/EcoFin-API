import {
  StockList,
  StockMovementList,
  type StockListQuery,
  type StockMovementsQuery,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'stock database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What the list functions return before the paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

/** I01: stock per product and branch, in the caller's accessible branches. */
export async function listStock(ctx: RequestContext, query: StockListQuery): Promise<StockList> {
  const { data, error } = await ctx.db.rpc('list_stock', {
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.category_id ? { p_category_id: query.category_id } : {}),
    ...(query.search ? { p_search: query.search } : {}),
    p_include_children: query.include_subcategories,
    p_low_only: query.low_only,
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  return StockList.parse({ ...ListResult.parse(data), page: query.page, pageSize: query.pageSize });
}

/** I01 drill-down: a product's ledger movements, newest first, with the running balance. */
export async function listStockMovements(
  ctx: RequestContext,
  query: StockMovementsQuery,
): Promise<StockMovementList> {
  const { data, error } = await ctx.db.rpc('list_stock_movements', {
    p_product_id: query.product_id,
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  return StockMovementList.parse({
    ...ListResult.parse(data),
    page: query.page,
    pageSize: query.pageSize,
  });
}
