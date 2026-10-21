import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';

/**
 * D01 owner dashboard (D87). One read answers how the business is doing today, for all the caller's
 * branches or one branch. Every tile is computed in SQL by the same definition as the page it links
 * to, so the number on the tile and the total on that page are the same number; the client never
 * adds money up. A tile is `null` when the caller lacks the permission key its detail page needs
 * (the client does not draw it). "Today" is the shop's date (organization time zone).
 * Words: overdue (متأخرات) with no fee anywhere; collections (تحصيلات); never interest.
 */

const Count = z.number().int().nonnegative();

/** `GET /api/dashboard` query. `branch_id` absent = every branch the caller can see. */
export const DashboardQuery = z.object({ branch_id: Uuid.optional() }).strict();
export type DashboardQuery = z.infer<typeof DashboardQuery>;

/** Sales dated today without the voided ones; detail: the sales history of today. */
export const DashboardSalesTile = z.object({
  count: Count,
  total: Money,
  paid_by_method: z.object({ cash: Money, bank_transfer: Money, store_credit: Money }),
  on_contract: Money,
});
export type DashboardSalesTile = z.infer<typeof DashboardSalesTile>;

/** K04's collections of the day (gross); detail: the day close. `in_field` was collected by collectors. */
export const DashboardCollectionsTile = z.object({ count: Count, total: Money, in_field: Money });
export type DashboardCollectionsTile = z.infer<typeof DashboardCollectionsTile>;

/** Cash by place. `total_in_branches` = safes + drawers + wallets (banks apart). */
export const DashboardCashTile = z.object({
  safes: Money,
  banks: Money,
  drawers: Money,
  wallets: Money,
  total_in_branches: Money,
});
export type DashboardCashTile = z.infer<typeof DashboardCashTile>;

/** Open shifts; `from_earlier_days` were opened before today (they block the day close). */
export const DashboardShiftsTile = z.object({
  count: Count,
  oldest_opened_at: IsoTimestamp.nullable(),
  from_earlier_days: Count,
});
export type DashboardShiftsTile = z.infer<typeof DashboardShiftsTile>;

/** Overdue installments (N04): contracts, the amount overdue and the customers behind them. */
export const DashboardOverdueTile = z.object({ contracts: Count, amount: Money, customers: Count });
export type DashboardOverdueTile = z.infer<typeof DashboardOverdueTile>;

/** Products below their minimum (a product below it in two branches counts twice). */
export const DashboardLowStockTile = z.object({ products: Count });
export type DashboardLowStockTile = z.infer<typeof DashboardLowStockTile>;

/** ETA receipts that need a person; `needs_action` = blocked + send_failed + rejected + due_soon + overdue. */
export const DashboardEtaTile = z.object({
  needs_action: Count,
  blocked: Count,
  send_failed: Count,
  rejected: Count,
  due_soon: Count,
  overdue: Count,
});
export type DashboardEtaTile = z.infer<typeof DashboardEtaTile>;

/** Days with activity in the last 14 days (today left out) that are not closed, and the branches they are in. */
export const DashboardUnclosedDaysTile = z.object({ days: Count, branches: Count });
export type DashboardUnclosedDaysTile = z.infer<typeof DashboardUnclosedDaysTile>;

/** Approvals waiting for the caller; a kind is `null` without its permission key. */
export const DashboardApprovalsTile = z.object({
  discount: Count.nullable(),
  purchase: Count.nullable(),
  credit: Count.nullable(),
  total: Count,
});
export type DashboardApprovalsTile = z.infer<typeof DashboardApprovalsTile>;

export const DASHBOARD_TILES = [
  'sales_today',
  'collections_today',
  'cash',
  'open_shifts',
  'overdue',
  'low_stock',
  'eta',
  'unclosed_days',
  'approvals',
] as const;
export type DashboardTileKey = (typeof DASHBOARD_TILES)[number];

/** `GET /api/dashboard`. Errors: BRANCH_NOT_FOUND (404), BRANCH_DENIED (403), VALIDATION_FAILED. */
export const OwnerDashboard = z.object({
  business_date: BusinessDate,
  /** null = all the caller's active branches. */
  branch_id: Uuid.nullable(),
  generated_at: IsoTimestamp,
  tiles: z.object({
    sales_today: DashboardSalesTile.nullable(),
    collections_today: DashboardCollectionsTile.nullable(),
    cash: DashboardCashTile.nullable(),
    open_shifts: DashboardShiftsTile.nullable(),
    overdue: DashboardOverdueTile.nullable(),
    low_stock: DashboardLowStockTile.nullable(),
    eta: DashboardEtaTile.nullable(),
    unclosed_days: DashboardUnclosedDaysTile.nullable(),
    approvals: DashboardApprovalsTile.nullable(),
  }),
});
export type OwnerDashboard = z.infer<typeof OwnerDashboard>;
