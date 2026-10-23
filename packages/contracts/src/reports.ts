import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';

/**
 * D02 sales and margin report (D89). One read answers what sold in a period and what it earned,
 * grouped by day, month, branch, employee, category, product, sale type or payment type. Every
 * number is a SQL aggregate sent as a string (money 2 decimals, percentages 1 decimal); the client
 * only formats it and never adds money up. Later report slices add theirs below (D03 receivables aging).
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

/**
 * D03 receivables aging (D90). One read answers who owes the shop money today and how late they are:
 * the open installment balances (current schedule lines of active or rescheduled contracts) grouped by
 * customer, the contract's selling branch, the customer's current collector or contract, split into age
 * buckets and into principal and profit. A line is late only after its due date plus the grace days of the
 * contract's policy (N04); its days late count from the due date. There are no fees (rule 4). Needs
 * `report.financial`. Money as strings; the client never adds money up.
 */

export const RECEIVABLES_GROUP_BY = ['customer', 'branch', 'collector', 'contract'] as const;
export const ReceivablesGroupBy = z.enum(RECEIVABLES_GROUP_BY);
export type ReceivablesGroupBy = z.infer<typeof ReceivablesGroupBy>;

export const RECEIVABLES_SORTS = [
  'outstanding_desc',
  'outstanding_asc',
  'overdue_desc',
  'late_90_plus_desc',
  'max_days_late_desc',
  'key_asc',
] as const;
export const ReceivablesSort = z.enum(RECEIVABLES_SORTS);
export type ReceivablesSort = z.infer<typeof ReceivablesSort>;

export const RECEIVABLES_BUCKETS = [
  'not_due',
  'late_1_30',
  'late_31_60',
  'late_61_90',
  'late_90_plus',
] as const;
export const ReceivablesBucket = z.enum(RECEIVABLES_BUCKETS);
export type ReceivablesBucket = z.infer<typeof ReceivablesBucket>;

/** `collector_id=none`: customers without a collector. */
export const RECEIVABLES_NO_COLLECTOR = 'none';
export const RECEIVABLES_MAX_MIN_DAYS = 100_000;
export const RECEIVABLES_MAX_Q = 100;

/**
 * `GET /api/reports/receivables` query. `q` (contract number prefix, customer name, phone, exact national id)
 * only with the customer or contract grouping. `min_days` keeps the contracts with a line late at least that
 * many days. A filter of the row's own dimension is the drill-down (`group_by=contract&customer_id=…`).
 */
export const ReceivablesQuery = z
  .object({
    group_by: ReceivablesGroupBy,
    branch_id: Uuid.optional(),
    collector_id: z.union([Uuid, z.literal(RECEIVABLES_NO_COLLECTOR)]).optional(),
    customer_id: Uuid.optional(),
    q: z.string().trim().min(1).max(RECEIVABLES_MAX_Q).optional(),
    min_days: z.coerce.number().int().min(1).max(RECEIVABLES_MAX_MIN_DAYS).optional(),
    sort: ReceivablesSort.optional(),
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
    if (q.q !== undefined && q.group_by !== 'customer' && q.group_by !== 'contract') {
      ctx.addIssue({
        code: 'custom',
        path: ['q'],
        message: 'Search needs the customer or contract grouping',
      });
    }
  });
export type ReceivablesQuery = z.infer<typeof ReceivablesQuery>;

/** The measures of one row or of the totals. `overdue` = the four late buckets; `overdue_pct` 1 decimal. */
export const ReceivablesMeasures = z.object({
  outstanding: Money,
  principal: Money,
  profit: Money,
  not_due: Money,
  late_1_30: Money,
  late_31_60: Money,
  late_61_90: Money,
  late_90_plus: Money,
  overdue: Money,
  overdue_pct: Pct.nullable(),
  contracts: Count,
  customers: Count,
  overdue_contracts: Count,
  max_days_late: Count.nullable(),
  oldest_due_date: BusinessDate.nullable(),
  migrated_contracts: Count,
});
export type ReceivablesMeasures = z.infer<typeof ReceivablesMeasures>;

const ReceivablesCustomerRef = z.object({
  id: Uuid,
  name: z.string(),
  phone: z.string().nullable(),
});
const ReceivablesEmployeeRef = z.object({ id: Uuid, name: z.string() });
const ReceivablesBranchRef = z.object({ id: Uuid, name: z.string(), code: z.string().nullable() });

/**
 * One row. `key` is the customer, branch, collector or contract id, or `none` (no collector, label null).
 * `label` is the name (the contract number for a contract); `sub_label` the first phone, the branch code or
 * the contract's customer. Each grouping adds its own references: `customer` (customer, contract),
 * `collector` (customer, collector; null = none), `branch` (branch, contract), `contract` (contract).
 */
export const ReceivablesRow = ReceivablesMeasures.extend({
  key: z.string(),
  label: z.string().nullable(),
  sub_label: z.string().nullable(),
  last_payment_at: IsoTimestamp.nullable(),
  customer: ReceivablesCustomerRef.optional(),
  collector: ReceivablesEmployeeRef.nullable().optional(),
  branch: ReceivablesBranchRef.optional(),
  contract: z
    .object({
      id: Uuid,
      number: z.string(),
      frequency: z.string(),
      status: z.string(),
      is_migrated: z.boolean(),
      next_due_date: BusinessDate.nullable(),
    })
    .optional(),
});
export type ReceivablesRow = z.infer<typeof ReceivablesRow>;

export const ReceivablesBucketSplit = z.object({
  amount: Money,
  principal: Money,
  profit: Money,
});
export type ReceivablesBucketSplit = z.infer<typeof ReceivablesBucketSplit>;

/** Summed per contract (each open contract in scope once), not from the rows; each bucket split into principal and profit. */
export const ReceivablesTotals = ReceivablesMeasures.extend({
  buckets: z.object({
    not_due: ReceivablesBucketSplit,
    late_1_30: ReceivablesBucketSplit,
    late_31_60: ReceivablesBucketSplit,
    late_61_90: ReceivablesBucketSplit,
    late_90_plus: ReceivablesBucketSplit,
  }),
});
export type ReceivablesTotals = z.infer<typeof ReceivablesTotals>;

/**
 * The rows of all pages minus the totals (must be 0); `rows_match` also needs principal + profit and the buckets to
 * add up to the outstanding and no open contract without a current schedule line.
 */
export const ReceivablesCheck = z.object({
  rows_match: z.boolean(),
  contracts_checked: Count,
  contracts_without_schedule: Count,
  differences: z.object({
    outstanding: Money,
    principal: Money,
    not_due: Money,
    late_1_30: Money,
    late_31_60: Money,
    late_61_90: Money,
    late_90_plus: Money,
  }),
});
export type ReceivablesCheck = z.infer<typeof ReceivablesCheck>;

export const ReceivablesReport = z.object({
  as_of: BusinessDate,
  generated_at: IsoTimestamp,
  group_by: ReceivablesGroupBy,
  filters: z.object({
    branch_id: Uuid.nullable(),
    collector_id: z.string().nullable(),
    customer_id: Uuid.nullable(),
    q: z.string().nullable(),
    min_days: z.number().int().nullable(),
  }),
  sort: ReceivablesSort,
  rows: z.array(ReceivablesRow),
  totals: ReceivablesTotals,
  check: ReceivablesCheck,
  total_count: Count,
  page: z.number().int().min(1),
  page_size: z.number().int().min(1).max(SALES_REPORT_MAX_PAGE_SIZE),
});
export type ReceivablesReport = z.infer<typeof ReceivablesReport>;
