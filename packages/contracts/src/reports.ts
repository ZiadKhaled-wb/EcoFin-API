import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';

/**
 * D02 sales and margin report (D89). One read answers what sold in a period and what it earned,
 * grouped by day, month, branch, employee, category, product, sale type or payment type. Every
 * number is a SQL aggregate sent as a string (money 2 decimals, percentages 1 decimal); the client
 * only formats it and never adds money up. Later report slices (D03-D0x) add their schemas here.
 *
 * Revenue is the amount after discounts without VAT; cost is the cost snapshot taken at the sale;
 * returns have their own columns (by the return's own date); an installment contract's profit is shown
 * apart (`contract_profit`) and is never part of the margin. Cost, margin and contract profit are `null`
 * without `report.financial` (`can_see_cost` false). Words: profit (ربح), never interest.
 */

export const SALES_REPORT_GROUP_BY = [
  'day',
  'month',
  'branch',
  'employee',
  'category',
  'product',
  'sale_type',
  'payment_type',
] as const;
export const SalesReportGroupBy = z.enum(SALES_REPORT_GROUP_BY);
export type SalesReportGroupBy = z.infer<typeof SalesReportGroupBy>;

export const SALES_REPORT_SORTS = [
  'revenue_desc',
  'revenue_asc',
  'margin_desc',
  'margin_asc',
  'quantity_desc',
  'net_revenue_desc',
  'key_asc',
] as const;
export const SalesReportSort = z.enum(SALES_REPORT_SORTS);
export type SalesReportSort = z.infer<typeof SalesReportSort>;

/** Sorts that need `report.financial` (they order by the margin). */
export const SALES_REPORT_COST_SORTS: readonly SalesReportSort[] = ['margin_desc', 'margin_asc'];

export const SalesReportSaleType = z.enum(['cash', 'installment']);
export type SalesReportSaleType = z.infer<typeof SalesReportSaleType>;

export const SALES_REPORT_MAX_DAYS = 366;
export const SALES_REPORT_MAX_PAGE_SIZE = 1000;
export const SALES_REPORT_DEFAULT_PAGE_SIZE = 50;

/** Whole days from `from` to `to`, both inclusive. */
export function salesReportDays(from: string, to: string): number {
  const ms = Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`);
  return Math.round(ms / 86_400_000) + 1;
}

/**
 * `GET /api/reports/sales` query. Dates are the shop's business dates, both inclusive, at most 366 days.
 * `category_level` `top` rolls every category up to the root of its tree (only for `group_by=category`).
 * Money by payment type cannot be split by product or category, so those filters are refused with it.
 */
export const SalesReportQuery = z
  .object({
    from: BusinessDate,
    to: BusinessDate,
    group_by: SalesReportGroupBy,
    branch_id: Uuid.optional(),
    employee_id: Uuid.optional(),
    category_id: Uuid.optional(),
    category_level: z.enum(['leaf', 'top']).default('leaf'),
    product_id: Uuid.optional(),
    sale_type: SalesReportSaleType.optional(),
    sort: SalesReportSort.optional(),
    page: z.coerce.number().int().min(1).default(1),
    page_size: z.coerce
      .number()
      .int()
      .min(1)
      .max(SALES_REPORT_MAX_PAGE_SIZE)
      .default(SALES_REPORT_DEFAULT_PAGE_SIZE),
  })
  .strict()
  .superRefine((q, ctx) => {
    if (q.from > q.to) {
      ctx.addIssue({ code: 'custom', path: ['to'], message: 'Invalid date range' });
    } else if (salesReportDays(q.from, q.to) > SALES_REPORT_MAX_DAYS) {
      ctx.addIssue({ code: 'custom', path: ['to'], message: 'At most 366 days' });
    }
    if (q.group_by === 'payment_type' && (q.category_id || q.product_id)) {
      ctx.addIssue({
        code: 'custom',
        path: [q.product_id ? 'product_id' : 'category_id'],
        message: 'Not available with the payment type grouping',
      });
    }
  });
export type SalesReportQuery = z.infer<typeof SalesReportQuery>;

const Count = z.number().int().nonnegative();
const Pct = z.string().regex(/^-?\d{1,7}(\.\d)?$/);

/**
 * The measures of one row or of the totals. A value a grouping does not have is `null` (quantity,
 * revenue, cost under `payment_type`; the cost group without `report.financial`).
 * `amount`, `refunded` and `net_amount` are the money columns of `payment_type` (and its totals).
 */
export const SalesReportMeasures = z.object({
  sales_count: Count.nullable(),
  quantity: Count.nullable(),
  revenue: Money.nullable(),
  gross: Money.nullable(),
  tax: Money.nullable(),
  discount: Money.nullable(),
  cost: Money.nullable(),
  margin: Money.nullable(),
  margin_pct: Pct.nullable(),
  return_count: Count.nullable(),
  returned_quantity: Count.nullable(),
  returned_gross: Money.nullable(),
  returned_revenue: Money.nullable(),
  returned_tax: Money.nullable(),
  returned_cost: Money.nullable(),
  returned_margin: Money.nullable(),
  net_quantity: z.number().int().nullable(),
  net_revenue: Money.nullable(),
  net_cost: Money.nullable(),
  net_margin: Money.nullable(),
  net_margin_pct: Pct.nullable(),
  contract_profit: Money.nullable(),
  contract_profit_returned: Money.nullable(),
  amount: Money.nullable(),
  refunded: Money.nullable(),
  net_amount: Money.nullable(),
});
export type SalesReportMeasures = z.infer<typeof SalesReportMeasures>;

/**
 * One row. `key` is the date (`day`), the first day of the month (`month`), an id, `cash` /
 * `installment` (`sale_type`), `cash` / `bank_transfer` / `store_credit` / `on_contract`
 * (`payment_type`) or `none` (a product without a category). `label` is the name (`YYYY-MM` for a month,
 * null for "no category"); `label_en` is a product's English name; `sub_label` the SKU or branch code.
 */
export const SalesReportRow = SalesReportMeasures.extend({
  key: z.string(),
  label: z.string().nullable(),
  label_en: z.string().nullable(),
  sub_label: z.string().nullable(),
});
export type SalesReportRow = z.infer<typeof SalesReportRow>;

/** Totals come from the document headers unless a row filter is set (then from the rows). */
export const SalesReportTotals = SalesReportMeasures;
export type SalesReportTotals = z.infer<typeof SalesReportTotals>;

/** The rows of all pages minus the totals; `null` when a row filter makes the headers incomparable. */
export const SalesReportCheck = z.object({
  rows_match: z.boolean(),
  differences: z.object({
    revenue: Money.nullable(),
    tax: Money.nullable(),
    cost: Money.nullable(),
    returned_revenue: Money.nullable(),
    gross: Money.nullable(),
    returned_gross: Money.nullable(),
  }),
});
export type SalesReportCheck = z.infer<typeof SalesReportCheck>;

export const SalesReport = z.object({
  from: BusinessDate,
  to: BusinessDate,
  group_by: SalesReportGroupBy,
  filters: z.object({
    branch_id: Uuid.nullable(),
    employee_id: Uuid.nullable(),
    category_id: Uuid.nullable(),
    category_level: z.enum(['leaf', 'top']).nullable(),
    product_id: Uuid.nullable(),
    sale_type: SalesReportSaleType.nullable(),
  }),
  sort: SalesReportSort,
  generated_at: IsoTimestamp,
  can_see_cost: z.boolean(),
  rows: z.array(SalesReportRow),
  totals: SalesReportTotals,
  check: SalesReportCheck.nullable(),
  total_count: Count,
  page: z.number().int().min(1),
  page_size: z.number().int().min(1).max(SALES_REPORT_MAX_PAGE_SIZE),
});
export type SalesReport = z.infer<typeof SalesReport>;
