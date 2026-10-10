import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';
import { PositiveMoney } from './cash.js';

/**
 * K03 expenses (D61). Money the shop spends, by category, paid from a vault (a safe or bank) or
 * from the caller's open shift (its drawer). Never edited or deleted: the owner reverses one.
 */
export const ExpenseCategory = z.object({
  id: Uuid,
  name: z.string(),
  archived_at: IsoTimestamp.nullable(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
});
export type ExpenseCategory = z.infer<typeof ExpenseCategory>;
export const ExpenseCategoryList = z.array(ExpenseCategory);
export type ExpenseCategoryList = z.infer<typeof ExpenseCategoryList>;

/** Create and rename. */
export const ExpenseCategoryBody = z.object({ name: z.string().trim().min(1).max(80) }).strict();
export type ExpenseCategoryBody = z.infer<typeof ExpenseCategoryBody>;
export const ExpenseCategoryIdParams = z.object({ id: Uuid }).strict();
export type ExpenseCategoryIdParams = z.infer<typeof ExpenseCategoryIdParams>;
const booleanFlag = (fallback: boolean) =>
  z
    .union([z.boolean(), z.enum(['true', 'false']).transform((v) => v === 'true')])
    .default(fallback);
export const ExpenseCategoryListQuery = z.object({ include_archived: booleanFlag(false) }).strict();
export type ExpenseCategoryListQuery = z.infer<typeof ExpenseCategoryListQuery>;

/**
 * `Idempotency-Key` header. The money leaves `cash_account_id` (a safe or bank of `branch_id`, or
 * a shop-wide bank), or with `from_shift` the drawer of the caller's open shift: one of the two.
 */
export const ExpenseCreateBody = z
  .object({
    category_id: Uuid,
    amount: PositiveMoney,
    branch_id: Uuid.optional(),
    cash_account_id: Uuid.optional(),
    from_shift: z.boolean().optional(),
    note: z.string().trim().max(500).optional(),
    /** A file registered with the purpose `expense_receipt`. */
    receipt_file_id: Uuid.optional(),
  })
  .strict()
  .refine((b) => (b.from_shift === true) !== (b.cash_account_id !== undefined), {
    message: 'An expense leaves a vault or the open shift, one of the two',
    path: ['cash_account_id'],
  })
  .refine((b) => b.from_shift === true || b.branch_id !== undefined, {
    message: 'A vault expense needs its branch',
    path: ['branch_id'],
  });
export type ExpenseCreateBody = z.infer<typeof ExpenseCreateBody>;
export type ExpenseCreateInput = z.input<typeof ExpenseCreateBody>;

/**
 * `Idempotency-Key` header. Owner only. `cash_account_id` is needed (and only allowed) when the
 * expense was paid from a shift that is closed by now: the vault the money goes back to.
 */
export const ExpenseReverseBody = z
  .object({ reason: z.string().trim().min(3).max(500), cash_account_id: Uuid.optional() })
  .strict();
export type ExpenseReverseBody = z.infer<typeof ExpenseReverseBody>;

export const ExpenseIdParams = z.object({ id: Uuid }).strict();
export type ExpenseIdParams = z.infer<typeof ExpenseIdParams>;

export const Expense = z.object({
  id: Uuid,
  number: z.string(),
  branch_id: Uuid,
  category_id: Uuid,
  category_name: z.string(),
  amount: Money,
  cash_account_id: Uuid,
  cash_account_name: z.string(),
  cash_account_kind: z.enum(['safe', 'bank', 'drawer', 'collector_wallet']),
  /** Set when the expense was paid from a shift's drawer. */
  shift_id: Uuid.nullable(),
  shift_number: z.string().nullable(),
  /** On a reversal: the reason. */
  note: z.string().nullable(),
  receipt_file_id: Uuid.nullable(),
  /** Set on a reversal: the expense it undoes. */
  reverses_expense_id: Uuid.nullable(),
  /** Set on a reversed expense: its reversal. */
  reversed_by_expense_id: Uuid.nullable(),
  business_date: BusinessDate,
  created_at: IsoTimestamp,
  created_by_name: z.string().nullable(),
});
export type Expense = z.infer<typeof Expense>;
export const ExpenseList = paginated(Expense);
export type ExpenseList = z.infer<typeof ExpenseList>;

export const ExpenseListQuery = PaginationQuery.extend({
  branch_id: Uuid.optional(),
  category_id: Uuid.optional(),
  from: BusinessDate.optional(),
  to: BusinessDate.optional(),
  /** `false`: only the expenses that count (no reversals, no reversed expenses). */
  include_reversals: booleanFlag(true),
})
  .strict()
  .refine((q) => q.from === undefined || q.to === undefined || q.from <= q.to, {
    message: '`from` must not be after `to`',
    path: ['from'],
  });
export type ExpenseListQuery = z.infer<typeof ExpenseListQuery>;

/** What was spent per category in a period (at most a year), reversed expenses left out. */
export const ExpenseReportQuery = z
  .object({ from: BusinessDate, to: BusinessDate, branch_id: Uuid.optional() })
  .strict()
  .refine((q) => q.from <= q.to, { message: '`from` must not be after `to`', path: ['from'] });
export type ExpenseReportQuery = z.infer<typeof ExpenseReportQuery>;
export const ExpenseReport = z.object({
  from: BusinessDate,
  to: BusinessDate,
  items: z.array(
    z.object({
      category_id: Uuid,
      category_name: z.string(),
      count: z.number().int().positive(),
      total: Money,
    }),
  ),
  count: z.number().int().nonnegative(),
  total: Money,
});
export type ExpenseReport = z.infer<typeof ExpenseReport>;
