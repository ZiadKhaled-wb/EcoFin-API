import {
  Category,
  CategoryList,
  type CategoryArchiveBody,
  type CategoryCreateBody,
  type CategoryUpdateBody,
  Uuid,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { AppError, mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'category database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}
export async function listCategories(ctx: RequestContext): Promise<Category[]> {
  const { data, error } = await ctx.db.rpc('list_categories');
  if (error) fail(error);
  return CategoryList.parse(data);
}
async function one(ctx: RequestContext, id: string) {
  const category = (await listCategories(ctx)).find((item) => item.id === id);
  if (!category) throw new AppError('Category not found.', 'CATEGORY_NOT_FOUND');
  return category;
}
export async function createCategory(ctx: RequestContext, body: CategoryCreateBody) {
  const { data, error } = await ctx.db.rpc('create_category', {
    p_name: body.name,
    // SQL default NULL: a top-level category leaves the key out.
    ...(body.parent_id ? { p_parent_id: body.parent_id } : {}),
  });
  if (error) fail(error);
  return one(ctx, Uuid.parse(data));
}
export async function updateCategory(ctx: RequestContext, id: string, body: CategoryUpdateBody) {
  const { error } = await ctx.db.rpc('update_category', { p_id: id, p_changes: body as Json });
  if (error) fail(error);
  return one(ctx, id);
}
export async function setCategoryArchived(
  ctx: RequestContext,
  id: string,
  archived: boolean,
  body: CategoryArchiveBody = {},
) {
  const { error } = await ctx.db.rpc('set_category_archived', {
    p_id: id,
    p_archived: archived,
    ...(body.move_to_category_id ? { p_move_to: body.move_to_category_id } : {}),
  });
  if (error) fail(error);
  return one(ctx, id);
}
