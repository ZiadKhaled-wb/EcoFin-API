import {
  Expense,
  ExpenseCategory,
  ExpenseCategoryList,
  ExpenseList,
  ExpenseReport,
  type ExpenseCreateBody,
  type ExpenseListQuery,
  type ExpenseReportQuery,
  type ExpenseReverseBody,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

function fail(error: unknown): never {
  logger.error({ err: error }, 'expense database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** What list_expenses returns before paging fields are added. */
const ListResult = z.object({ items: z.array(z.unknown()), total: z.number().int().min(0) });

/** K03: the shop's expense categories, by name (archived ones only when asked). */
export async function listExpenseCategories(
  ctx: RequestContext,
  includeArchived: boolean,
): Promise<ExpenseCategoryList> {
  const { data, error } = await ctx.db.rpc('list_expense_categories', {
    p_include_archived: includeArchived,
  });
  if (error) fail(error);
  return ExpenseCategoryList.parse(data);
}

export async function createExpenseCategory(
  ctx: RequestContext,
  name: string,
): Promise<ExpenseCategory> {
  const { data, error } = await ctx.db.rpc('create_expense_category', { p_name: name });
  if (error) fail(error);
  return ExpenseCategory.parse(data);
}

export async function renameExpenseCategory(
  ctx: RequestContext,
  id: string,
  name: string,
): Promise<ExpenseCategory> {
  const { data, error } = await ctx.db.rpc('rename_expense_category', { p_id: id, p_name: name });
  if (error) fail(error);
  return ExpenseCategory.parse(data);
}

/** An archived category keeps its expenses and takes no new one. */
export async function setExpenseCategoryArchived(
  ctx: RequestContext,
  id: string,
  archived: boolean,
): Promise<ExpenseCategory> {
  const { data, error } = await ctx.db.rpc('set_expense_category_archived', {
    p_id: id,
    p_archived: archived,
  });
  if (error) fail(error);
  return ExpenseCategory.parse(data);
}

/** K03: expenses of the caller's branches, newest first; reversals are their own rows. */
export async function listExpenses(
  ctx: RequestContext,
  query: ExpenseListQuery,
): Promise<ExpenseList> {
  const { data, error } = await ctx.db.rpc('list_expenses', {
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.category_id ? { p_category_id: query.category_id } : {}),
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    p_include_reversals: query.include_reversals,
    p_limit: query.pageSize,
    p_offset: (query.page - 1) * query.pageSize,
  });
  if (error) fail(error);
  const result = ListResult.parse(data);
  return ExpenseList.parse({ ...result, page: query.page, pageSize: query.pageSize });
}

export async function getExpense(ctx: RequestContext, id: string): Promise<Expense> {
  const { data, error } = await ctx.db.rpc('get_expense', { p_id: id });
  if (error) fail(error);
  return Expense.parse(data);
}

/** What was spent per category in a period, reversed expenses left out. */
export async function expenseReport(
  ctx: RequestContext,
  query: ExpenseReportQuery,
): Promise<ExpenseReport> {
  const { data, error } = await ctx.db.rpc('expense_report', {
    p_from: query.from,
    p_to: query.to,
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
  });
  if (error) fail(error);
  return ExpenseReport.parse(data);
}

/**
 * K03 (D61): an expense paid from a vault or from the caller's open shift. The same idempotency
 * key again returns the first expense and spends nothing.
 */
export async function postExpense(
  ctx: RequestContext,
  body: ExpenseCreateBody,
  idempotencyKey: string,
): Promise<Expense> {
  const { data, error } = await ctx.db.rpc('post_expense', {
    p_category_id: body.category_id,
    p_amount: body.amount,
    p_idempotency_key: idempotencyKey,
    ...(body.from_shift
      ? { p_from_shift: true }
      : {
          ...(body.branch_id ? { p_branch_id: body.branch_id } : {}),
          ...(body.cash_account_id ? { p_cash_account_id: body.cash_account_id } : {}),
        }),
    ...(body.note ? { p_note: body.note } : {}),
    ...(body.receipt_file_id ? { p_receipt_file_id: body.receipt_file_id } : {}),
  });
  if (error) fail(error);
  return Expense.parse(data);
}

/** The owner undoes an expense: a linked reversal and the money back. */
export async function reverseExpense(
  ctx: RequestContext,
  id: string,
  body: ExpenseReverseBody,
  idempotencyKey: string,
): Promise<Expense> {
  const { data, error } = await ctx.db.rpc('reverse_expense', {
    p_id: id,
    p_reason: body.reason,
    p_idempotency_key: idempotencyKey,
    ...(body.cash_account_id ? { p_cash_account_id: body.cash_account_id } : {}),
  });
  if (error) fail(error);
  return Expense.parse(data);
}
