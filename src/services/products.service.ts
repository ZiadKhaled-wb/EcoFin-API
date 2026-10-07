import {
  Product,
  ProductList,
  ProductUnitList,
  type ProductCreateBody,
  type ProductListQuery,
  type ProductUnitsQuery,
  type ProductUpdateBody,
  Uuid,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'product database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What list_products returns before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

export async function listProducts(
  ctx: RequestContext,
  query: ProductListQuery,
): Promise<ProductList> {
  const { data, error } = await ctx.db.rpc('list_products', {
    ...(query.search ? { p_search: query.search } : {}),
    ...(query.category_id ? { p_category_id: query.category_id } : {}),
    p_include_children: query.include_subcategories,
    p_status: query.status,
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return ProductList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getProduct(ctx: RequestContext, id: string): Promise<Product> {
  const { data, error } = await ctx.db.rpc('get_product', { p_id: id });
  if (error) fail(error);
  return Product.parse(data);
}

/** The POS: an ACTIVE product by exact barcode, then by SKU. */
export async function lookupProduct(ctx: RequestContext, code: string): Promise<Product> {
  const { data, error } = await ctx.db.rpc('lookup_product', { p_code: code });
  if (error) fail(error);
  return Product.parse(data);
}

export async function createProduct(
  ctx: RequestContext,
  body: ProductCreateBody,
): Promise<Product> {
  const { data, error } = await ctx.db.rpc('create_product', { p: body as Json });
  if (error) fail(error);
  return getProduct(ctx, Uuid.parse(data));
}

export async function updateProduct(
  ctx: RequestContext,
  id: string,
  body: ProductUpdateBody,
): Promise<Product> {
  const { error } = await ctx.db.rpc('update_product', { p_id: id, p_changes: body as Json });
  if (error) fail(error);
  return getProduct(ctx, id);
}

export async function setProductArchived(
  ctx: RequestContext,
  id: string,
  archived: boolean,
): Promise<Product> {
  const { error } = await ctx.db.rpc('set_product_archived', { p_id: id, p_archived: archived });
  if (error) fail(error);
  return getProduct(ctx, id);
}

/** C03 labels: the product's serialized units in the caller's accessible branches. */
export async function listProductUnits(
  ctx: RequestContext,
  id: string,
  query: ProductUnitsQuery,
): Promise<ProductUnitList> {
  const { data, error } = await ctx.db.rpc('list_product_units', {
    p_product_id: id,
    p_status: query.status,
  });
  if (error) fail(error);
  return ProductUnitList.parse(data);
}
