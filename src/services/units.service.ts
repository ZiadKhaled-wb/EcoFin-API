import {
  UnitDetail,
  UnitList,
  UnitRegistration,
  type UnitRegisterBody,
  type UnitSearchQuery,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'units database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

/** I04: registers serials the shop holds (opening stock); the same key again returns the batch. */
export async function registerUnits(
  ctx: RequestContext,
  body: UnitRegisterBody,
  idempotencyKey: string,
): Promise<UnitRegistration> {
  const { data, error } = await ctx.db.rpc('register_units', {
    p_product_id: body.product_id,
    p_branch_id: body.branch_id,
    p_cost: body.cost,
    p_serials: body.serials,
    p_note: body.note ?? null,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error);
  return UnitRegistration.parse(data);
}

/** Serial prefix search in the caller's branches. */
export async function searchUnits(ctx: RequestContext, query: UnitSearchQuery): Promise<UnitList> {
  const { data, error } = await ctx.db.rpc('search_units', {
    ...(query.search ? { p_search: query.search } : {}),
    ...(query.status ? { p_status: query.status } : {}),
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  return UnitList.parse({ ...ListResult.parse(data), page: query.page, pageSize: query.pageSize });
}

/** A unit and its full history, by id or by the exact serial. */
export async function getUnit(
  ctx: RequestContext,
  by: { id: string } | { serial: string },
): Promise<UnitDetail> {
  const { data, error } =
    'id' in by
      ? await ctx.db.rpc('get_unit', { p_id: by.id })
      : await ctx.db.rpc('find_unit', { p_serial: by.serial });
  if (error) fail(error);
  return UnitDetail.parse(data);
}
