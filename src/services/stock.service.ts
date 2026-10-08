import {
  StockAdjustment,
  StockAdjustmentList,
  StockCount,
  StockCountDetail,
  StockCountLine,
  StockCountList,
  StockList,
  StockMovementList,
  type StockAdjustmentCreateBody,
  type StockAdjustmentListQuery,
  type StockCountCreateBody,
  type StockCountDetailQuery,
  type StockCountLinesBody,
  type StockCountListQuery,
  type StockCountPostBody,
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

/** limit / offset for a page. */
const paging = (q: { page: number; pageSize: number }) => ({
  p_limit: q.pageSize,
  p_offset: (q.page - 1) * q.pageSize,
});

/** I01: stock per product and branch, in the caller's accessible branches. */
export async function listStock(ctx: RequestContext, query: StockListQuery): Promise<StockList> {
  const { data, error } = await ctx.db.rpc('list_stock', {
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.category_id ? { p_category_id: query.category_id } : {}),
    ...(query.search ? { p_search: query.search } : {}),
    p_include_children: query.include_subcategories,
    p_low_only: query.low_only,
    ...paging(query),
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
    ...paging(query),
  });
  if (error) fail(error);
  return StockMovementList.parse({
    ...ListResult.parse(data),
    page: query.page,
    pageSize: query.pageSize,
  });
}

/** I02: posts an adjustment; the same idempotency key again returns the first one. */
export async function postAdjustment(
  ctx: RequestContext,
  body: StockAdjustmentCreateBody,
  idempotencyKey: string,
): Promise<StockAdjustment> {
  const { data, error } = await ctx.db.rpc('post_stock_adjustment', {
    p_branch_id: body.branch_id,
    p_reason: body.reason,
    p_note: body.note ?? null,
    p_lines: body.lines.map((l) => ({
      product_id: l.product_id,
      unit_id: l.unit_id ?? null,
      quantity: l.quantity,
    })),
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return StockAdjustment.parse(data);
}

export async function listAdjustments(
  ctx: RequestContext,
  query: StockAdjustmentListQuery,
): Promise<StockAdjustmentList> {
  const { data, error } = await ctx.db.rpc('list_stock_adjustments', {
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.reason ? { p_reason: query.reason } : {}),
    ...paging(query),
  });
  if (error) fail(error);
  return StockAdjustmentList.parse({
    ...ListResult.parse(data),
    page: query.page,
    pageSize: query.pageSize,
  });
}

export async function getAdjustment(ctx: RequestContext, id: string): Promise<StockAdjustment> {
  const { data, error } = await ctx.db.rpc('get_stock_adjustment', { p_id: id });
  if (error) fail(error);
  return StockAdjustment.parse(data);
}

/** I02: opens a count sheet (the same idempotency key again returns the same count). */
export async function createCount(
  ctx: RequestContext,
  body: StockCountCreateBody,
  idempotencyKey: string,
): Promise<StockCount> {
  const { data, error } = await ctx.db.rpc('create_stock_count', {
    p_branch_id: body.branch_id,
    p_category_id: body.category_id ?? null,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return StockCount.parse(data);
}

export async function listCounts(
  ctx: RequestContext,
  query: StockCountListQuery,
): Promise<StockCountList> {
  const { data, error } = await ctx.db.rpc('list_stock_counts', {
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.status ? { p_status: query.status } : {}),
    ...paging(query),
  });
  if (error) fail(error);
  return StockCountList.parse({
    ...ListResult.parse(data),
    page: query.page,
    pageSize: query.pageSize,
  });
}

/** A count and one page of its lines (filter: all, uncounted, different; search). */
export async function getCount(
  ctx: RequestContext,
  id: string,
  query: StockCountDetailQuery,
): Promise<StockCountDetail> {
  const { data, error } = await ctx.db.rpc('get_stock_count', {
    p_id: id,
    p_filter: query.filter,
    ...(query.search ? { p_search: query.search } : {}),
    ...paging(query),
  });
  if (error) fail(error);
  const raw = z.object({ lines: ListResult }).passthrough().parse(data);
  return StockCountDetail.parse({
    ...raw,
    lines: { ...raw.lines, page: query.page, pageSize: query.pageSize },
  });
}

/** Saves counted quantities; answers the count's new summary. */
export async function saveCountLines(
  ctx: RequestContext,
  id: string,
  body: StockCountLinesBody,
): Promise<StockCount> {
  const { data, error } = await ctx.db.rpc('save_stock_count_lines', {
    p_count_id: id,
    p_lines: body.lines.map((l) => ({
      product_id: l.product_id,
      unit_id: l.unit_id ?? null,
      counted_qty: l.counted_qty,
    })),
  });
  if (error) fail(error);
  return StockCount.parse(data);
}

/** A scanned serial, barcode or SKU; answers the counted line. */
export async function scanCount(
  ctx: RequestContext,
  id: string,
  code: string,
): Promise<StockCountLine> {
  const { data, error } = await ctx.db.rpc('scan_stock_count', { p_count_id: id, p_code: code });
  if (error) fail(error);
  return StockCountLine.parse(data);
}

/** Posts a count: the stock becomes the counted numbers (one 'count' adjustment). */
export async function postCount(
  ctx: RequestContext,
  id: string,
  body: StockCountPostBody,
  idempotencyKey: string,
): Promise<StockCount> {
  const { data, error } = await ctx.db.rpc('post_stock_count', {
    p_count_id: id,
    p_uncounted_as_zero: body.uncounted_as_zero,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return StockCount.parse(data);
}

export async function cancelCount(ctx: RequestContext, id: string): Promise<StockCount> {
  const { data, error } = await ctx.db.rpc('cancel_stock_count', { p_count_id: id });
  if (error) fail(error);
  return StockCount.parse(data);
}
