import { z } from 'zod';
import { IsoTimestamp, Uuid } from './common.js';

/**
 * C01 product categories. The list is ordered active first, then archived; inside
 * each, parents in name order, each followed by its children in name order.
 * `active_product_count` counts the category's own active products, never its
 * children's. Nesting is exactly one level: a category with children can't become
 * a child, and only a top-level category can be a parent.
 */
export const Category = z.object({
  id: Uuid,
  name: z.string(),
  parent_id: Uuid.nullable(),
  archived_at: IsoTimestamp.nullable(),
  active_product_count: z.number().int().nonnegative(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
});
export type Category = z.infer<typeof Category>;
export const CategoryList = z.array(Category);

const fields = {
  name: z.string().trim().min(1).max(60),
  parent_id: Uuid.nullable().optional(),
};
export const CategoryCreateBody = z.object({ ...fields }).strict();
export type CategoryCreateBody = z.infer<typeof CategoryCreateBody>;
export const CategoryUpdateBody = z
  .object({ ...fields })
  .partial()
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to change' });
export type CategoryUpdateBody = z.infer<typeof CategoryUpdateBody>;
export const CategoryIdParams = z.object({ id: Uuid }).strict();
export type CategoryIdParams = z.infer<typeof CategoryIdParams>;
/** Archive body: where to move the category's active products before archiving. */
export const CategoryArchiveBody = z.object({ move_to_category_id: Uuid.optional() }).strict();
export type CategoryArchiveBody = z.infer<typeof CategoryArchiveBody>;
/** CATEGORY_IN_USE details: why the archive was refused. */
export const CategoryInUseDetail = z
  .object({
    active_products: z.number().int().nonnegative(),
    active_children: z.number().int().nonnegative(),
  })
  .strict();
export type CategoryInUseDetail = z.infer<typeof CategoryInUseDetail>;
