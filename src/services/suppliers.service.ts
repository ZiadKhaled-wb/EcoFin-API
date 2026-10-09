import {
  Supplier,
  SupplierList,
  SupplierStatement,
  type SupplierCreateBody,
  type SupplierListQuery,
  type SupplierStatementQuery,
  type SupplierUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'supplier database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What list_suppliers returns before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

export async function listSuppliers(
  ctx: RequestContext,
  query: SupplierListQuery,
): Promise<SupplierList> {
  const { data, error } = await ctx.db.rpc('list_suppliers', {
    ...(query.search ? { p_search: query.search } : {}),
    p_status: query.status,
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return SupplierList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

/** Archived suppliers are readable too. */
export async function getSupplier(ctx: RequestContext, id: string): Promise<Supplier> {
  const { data, error } = await ctx.db.rpc('get_supplier', { p_id: id });
  if (error) fail(error);
  return Supplier.parse(data);
}

/** Shop-wide statement (every branch) with the running balance. */
export async function getSupplierStatement(
  ctx: RequestContext,
  id: string,
  query: SupplierStatementQuery,
): Promise<SupplierStatement> {
  const { data, error } = await ctx.db.rpc('supplier_statement', {
    p_id: id,
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
  });
  if (error) fail(error);
  return SupplierStatement.parse(data);
}

export async function createSupplier(
  ctx: RequestContext,
  body: SupplierCreateBody,
): Promise<Supplier> {
  const { data, error } = await ctx.db.rpc('create_supplier', { p: body as Json });
  if (error) fail(error);
  return Supplier.parse(data);
}

export async function updateSupplier(
  ctx: RequestContext,
  id: string,
  body: SupplierUpdateBody,
): Promise<Supplier> {
  const { data, error } = await ctx.db.rpc('update_supplier', {
    p_id: id,
    p_changes: body as Json,
  });
  if (error) fail(error);
  return Supplier.parse(data);
}

/** Archive is refused with a balance or open documents; restore re-checks name and phone. */
export async function setSupplierArchived(
  ctx: RequestContext,
  id: string,
  archived: boolean,
): Promise<Supplier> {
  const { data, error } = await ctx.db.rpc('set_supplier_archived', {
    p_id: id,
    p_archived: archived,
  });
  if (error) fail(error);
  return Supplier.parse(data);
}
