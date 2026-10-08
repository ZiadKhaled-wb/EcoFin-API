import { z } from 'zod';
import { IsoTimestamp, BusinessDate, PaginationQuery, Uuid, paginated } from './common.js';

/**
 * I01 stock view (D47). One row per product and branch, read from `stock_levels` (kept from the
 * ledger by trigger): `available = on_hand − reserved`; `damaged` is the damaged stock state;
 * `in_transit` is sent-not-received transfer stock coming INTO the branch. `min_level` is the
 * product's min stock, or the shop's global minimum; `low` = available < min_level.
 */
export const StockRow = z.object({
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  barcode: z.string().nullable(),
  category_id: Uuid.nullable(),
  is_serialized: z.boolean(),
  archived_at: IsoTimestamp.nullable(),
  branch_id: Uuid,
  on_hand: z.number().int(),
  reserved: z.number().int().nonnegative(),
  available: z.number().int(),
  damaged: z.number().int(),
  in_transit: z.number().int().nonnegative(),
  min_level: z.number().int().nonnegative(),
  low: z.boolean(),
});
export type StockRow = z.infer<typeof StockRow>;
export const StockList = paginated(StockRow);
export type StockList = z.infer<typeof StockList>;

const QueryFlag = z.enum(['true', 'false']).transform((v) => v === 'true');

export const StockListQuery = PaginationQuery.extend({
  branch_id: Uuid.optional(),
  category_id: Uuid.optional(),
  include_subcategories: QueryFlag.default('true'),
  search: z
    .string()
    .trim()
    .max(100)
    .optional()
    .transform((v) => (v ? v : undefined)),
  low_only: QueryFlag.default('false'),
}).strict();
export type StockListQuery = z.infer<typeof StockListQuery>;

/** Values of `public.stock_movement_type`. */
export const StockMovementType = z.enum([
  'opening',
  'purchase_in',
  'purchase_return_out',
  'sale_out',
  'sale_return_in',
  'transfer_out',
  'transfer_in',
  'adjustment',
  'delivery_out',
  'claim_out',
  'claim_in',
]);
export type StockMovementType = z.infer<typeof StockMovementType>;
export const StockState = z.enum(['sellable', 'damaged']);
export type StockState = z.infer<typeof StockState>;

/**
 * One ledger movement (the I01 drill-down; I05 adds filters and document links). `balance_after`
 * is the running on-hand of that branch and stock state after this movement.
 */
export const StockMovement = z.object({
  id: Uuid,
  created_at: IsoTimestamp,
  business_date: BusinessDate,
  branch_id: Uuid,
  type: StockMovementType,
  stock_state: StockState,
  quantity: z.number().int(),
  balance_after: z.number().int(),
  serial: z.string().nullable(),
  source_type: z.string(),
  source_id: Uuid,
  reverses_movement_id: Uuid.nullable(),
  created_by_name: z.string().nullable(),
});
export type StockMovement = z.infer<typeof StockMovement>;
export const StockMovementList = paginated(StockMovement);
export type StockMovementList = z.infer<typeof StockMovementList>;

export const StockMovementsQuery = PaginationQuery.extend({
  product_id: Uuid,
  branch_id: Uuid.optional(),
}).strict();
export type StockMovementsQuery = z.infer<typeof StockMovementsQuery>;
