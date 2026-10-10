import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  createExpenseCategory,
  expenseReport,
  getExpense,
  listExpenseCategories,
  listExpenses,
  postExpense,
  renameExpenseCategory,
  reverseExpense,
  setExpenseCategoryArchived,
} from './expenses.service';

const ID = 'a0610000-0000-4000-8000-000000000001';
const BRANCH = 'a0610000-0000-4000-8000-000000000002';
const SAFE = 'a0610000-0000-4000-8000-000000000003';
const CATEGORY = 'a0610000-0000-4000-8000-000000000004';
const FILE = 'a0610000-0000-4000-8000-000000000005';
const KEY = 'expense-key-0001';
const ts = '2026-10-11T08:00:00.000Z';

const category = { id: CATEGORY, name: 'Rent', archived_at: null, created_at: ts, updated_at: ts };
const expense = {
  id: ID,
  number: 'MAIN-EX-26-000001',
  branch_id: BRANCH,
  category_id: CATEGORY,
  category_name: 'Rent',
  amount: '150.00',
  cash_account_id: SAFE,
  cash_account_name: 'Main safe',
  cash_account_kind: 'safe',
  shift_id: null,
  shift_number: null,
  note: null,
  receipt_file_id: null,
  reverses_expense_id: null,
  reversed_by_expense_id: null,
  business_date: '2026-10-11',
  created_at: ts,
  created_by_name: 'Owner',
};

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'OWNER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('K03 expense service', () => {
  it('categories: list, create, rename, archive and restore', async () => {
    const { db, ctx } = setup();
    db.queue({ data: [category], error: null });
    expect(await listExpenseCategories(ctx, true)).toHaveLength(1);
    expect(db.rpc).toHaveBeenLastCalledWith('list_expense_categories', {
      p_include_archived: true,
    });
    db.queue({ data: category, error: null });
    await createExpenseCategory(ctx, 'Rent');
    expect(db.rpc).toHaveBeenLastCalledWith('create_expense_category', { p_name: 'Rent' });
    db.queue({ data: category, error: null });
    await renameExpenseCategory(ctx, CATEGORY, 'Rent');
    expect(db.rpc).toHaveBeenLastCalledWith('rename_expense_category', {
      p_id: CATEGORY,
      p_name: 'Rent',
    });
    db.queue({ data: { ...category, archived_at: ts }, error: null });
    expect((await setExpenseCategoryArchived(ctx, CATEGORY, true)).archived_at).toBe(ts);
    expect(db.rpc).toHaveBeenLastCalledWith('set_expense_category_archived', {
      p_id: CATEGORY,
      p_archived: true,
    });
    db.queue({ data: null, error: { code: 'P0001', message: 'EXPENSE_CATEGORY_NAME_TAKEN' } });
    await expect(createExpenseCategory(ctx, 'Rent')).rejects.toMatchObject({
      statusCode: 409,
      code: 'EXPENSE_CATEGORY_NAME_TAKEN',
    });
  });

  it('posts from a vault with its branch, or from the open shift (never both)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: expense, error: null });
    await postExpense(
      ctx,
      { category_id: CATEGORY, amount: '150.00', branch_id: BRANCH, cash_account_id: SAFE },
      KEY,
    );
    expect(db.rpc).toHaveBeenLastCalledWith('post_expense', {
      p_category_id: CATEGORY,
      p_amount: '150.00',
      p_idempotency_key: KEY,
      p_branch_id: BRANCH,
      p_cash_account_id: SAFE,
    });
    db.queue({ data: expense, error: null });
    await postExpense(
      ctx,
      {
        category_id: CATEGORY,
        amount: '20.00',
        from_shift: true,
        note: 'Taxi',
        receipt_file_id: FILE,
      },
      KEY,
    );
    expect(db.rpc).toHaveBeenLastCalledWith('post_expense', {
      p_category_id: CATEGORY,
      p_amount: '20.00',
      p_idempotency_key: KEY,
      p_from_shift: true,
      p_note: 'Taxi',
      p_receipt_file_id: FILE,
    });
    for (const [message, status] of [
      ['SHIFT_REQUIRED', 409],
      ['INSUFFICIENT_FUNDS', 409],
      ['EXPENSE_CATEGORY_ARCHIVED', 409],
      ['EXPENSE_CATEGORY_NOT_FOUND', 404],
    ] as const) {
      db.queue({ data: null, error: { code: 'P0001', message } });
      await expect(
        postExpense(ctx, { category_id: CATEGORY, amount: '20.00', from_shift: true }, KEY),
      ).rejects.toMatchObject({ statusCode: status, code: message });
    }
  });

  it('reverses with the reason; the vault only when given; owner only', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { ...expense, reverses_expense_id: ID }, error: null });
    await reverseExpense(ctx, ID, { reason: 'Entered twice' }, KEY);
    expect(db.rpc).toHaveBeenLastCalledWith('reverse_expense', {
      p_id: ID,
      p_reason: 'Entered twice',
      p_idempotency_key: KEY,
    });
    db.queue({ data: { ...expense, reverses_expense_id: ID }, error: null });
    await reverseExpense(ctx, ID, { reason: 'Entered twice', cash_account_id: SAFE }, KEY);
    expect(db.rpc).toHaveBeenLastCalledWith('reverse_expense', {
      p_id: ID,
      p_reason: 'Entered twice',
      p_idempotency_key: KEY,
      p_cash_account_id: SAFE,
    });
    db.queue({ data: null, error: { code: '42501', message: 'APPROVAL_OWNER_ONLY' } });
    await expect(reverseExpense(ctx, ID, { reason: 'Entered twice' }, KEY)).rejects.toMatchObject({
      statusCode: 403,
      code: 'APPROVAL_OWNER_ONLY',
    });
    db.queue({ data: null, error: { code: 'P0001', message: 'EXPENSE_ALREADY_REVERSED' } });
    await expect(reverseExpense(ctx, ID, { reason: 'Entered twice' }, KEY)).rejects.toMatchObject({
      statusCode: 409,
      code: 'EXPENSE_ALREADY_REVERSED',
    });
  });

  it('lists with the filters and paging, reads one and the report', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [expense], total: 7 }, error: null });
    const list = await listExpenses(ctx, {
      page: 2,
      pageSize: 5,
      branch_id: BRANCH,
      category_id: CATEGORY,
      from: '2026-10-01',
      to: '2026-10-31',
      include_reversals: false,
    });
    expect(list).toMatchObject({ total: 7, page: 2, pageSize: 5 });
    expect(db.rpc).toHaveBeenLastCalledWith('list_expenses', {
      p_branch_id: BRANCH,
      p_category_id: CATEGORY,
      p_from: '2026-10-01',
      p_to: '2026-10-31',
      p_include_reversals: false,
      p_limit: 5,
      p_offset: 5,
    });
    db.queue({ data: { items: [], total: 0 }, error: null });
    await listExpenses(ctx, { page: 1, pageSize: 50, include_reversals: true });
    expect(db.rpc).toHaveBeenLastCalledWith('list_expenses', {
      p_include_reversals: true,
      p_limit: 50,
      p_offset: 0,
    });
    db.queue({ data: expense, error: null });
    expect((await getExpense(ctx, ID)).number).toBe('MAIN-EX-26-000001');
    db.queue({ data: null, error: { code: 'P0001', message: 'EXPENSE_NOT_FOUND' } });
    await expect(getExpense(ctx, ID)).rejects.toMatchObject({ statusCode: 404 });
    db.queue({
      data: {
        from: '2026-10-01',
        to: '2026-10-31',
        items: [{ category_id: CATEGORY, category_name: 'Rent', count: 1, total: '150.00' }],
        count: 1,
        total: '150.00',
      },
      error: null,
    });
    const report = await expenseReport(ctx, { from: '2026-10-01', to: '2026-10-31' });
    expect(report.total).toBe('150.00');
    expect(db.rpc).toHaveBeenLastCalledWith('expense_report', {
      p_from: '2026-10-01',
      p_to: '2026-10-31',
    });
  });
});
