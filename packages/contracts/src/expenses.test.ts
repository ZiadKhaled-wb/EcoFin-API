import { describe, it, expect } from 'vitest';
import {
  ExpenseCategoryBody,
  ExpenseCategoryListQuery,
  ExpenseCreateBody,
  ExpenseListQuery,
  ExpenseReport,
  ExpenseReportQuery,
  ExpenseReverseBody,
} from './expenses.js';
import { errorCodeHttpStatus } from './errors.js';

const CATEGORY = 'a0610000-0000-4000-8000-000000000001';
const BRANCH = 'a0610000-0000-4000-8000-000000000002';
const SAFE = 'a0610000-0000-4000-8000-000000000003';

describe('K03 expense contracts', () => {
  it('category: a trimmed name of 1-80; the list flag reads a query string', () => {
    expect(ExpenseCategoryBody.parse({ name: '  Rent ' }).name).toBe('Rent');
    expect(ExpenseCategoryBody.safeParse({ name: '   ' }).success).toBe(false);
    expect(ExpenseCategoryBody.safeParse({ name: 'x'.repeat(81) }).success).toBe(false);
    expect(ExpenseCategoryBody.safeParse({ name: 'Rent', organization_id: SAFE }).success).toBe(
      false,
    );
    expect(ExpenseCategoryListQuery.parse({}).include_archived).toBe(false);
    expect(ExpenseCategoryListQuery.parse({ include_archived: 'true' }).include_archived).toBe(
      true,
    );
    expect(ExpenseCategoryListQuery.safeParse({ include_archived: 'yes' }).success).toBe(false);
  });

  it('create: a vault with its branch, or the open shift, one of the two', () => {
    const base = { category_id: CATEGORY, amount: '150.00' };
    expect(
      ExpenseCreateBody.safeParse({ ...base, branch_id: BRANCH, cash_account_id: SAFE }).success,
    ).toBe(true);
    expect(ExpenseCreateBody.safeParse({ ...base, from_shift: true }).success).toBe(true);
    expect(ExpenseCreateBody.safeParse(base).success).toBe(false);
    expect(ExpenseCreateBody.safeParse({ ...base, from_shift: false }).success).toBe(false);
    expect(ExpenseCreateBody.safeParse({ ...base, cash_account_id: SAFE }).success).toBe(false);
    expect(
      ExpenseCreateBody.safeParse({ ...base, from_shift: true, cash_account_id: SAFE }).success,
    ).toBe(false);
    for (const amount of ['0.00', '-5.00', '1.234', 'abc']) {
      expect(ExpenseCreateBody.safeParse({ ...base, amount, from_shift: true }).success).toBe(
        false,
      );
    }
    expect(
      ExpenseCreateBody.safeParse({ ...base, from_shift: true, organization_id: SAFE }).success,
    ).toBe(false);
    expect(
      ExpenseCreateBody.parse({ ...base, from_shift: true, note: '  Taxi ', receipt_file_id: SAFE })
        .note,
    ).toBe('Taxi');
  });

  it('reverse: a reason of 3-500 and an optional vault', () => {
    expect(ExpenseReverseBody.parse({ reason: '  Entered twice ' }).reason).toBe('Entered twice');
    expect(ExpenseReverseBody.safeParse({ reason: 'no' }).success).toBe(false);
    expect(
      ExpenseReverseBody.safeParse({ reason: 'Entered twice', cash_account_id: SAFE }).success,
    ).toBe(true);
  });

  it('list and report queries, the report and the error codes', () => {
    expect(ExpenseListQuery.parse({})).toMatchObject({ page: 1, include_reversals: true });
    expect(ExpenseListQuery.parse({ include_reversals: 'false' }).include_reversals).toBe(false);
    expect(ExpenseListQuery.safeParse({ from: '2026-10-02', to: '2026-10-01' }).success).toBe(
      false,
    );
    expect(ExpenseListQuery.safeParse({ organization_id: SAFE }).success).toBe(false);
    expect(ExpenseReportQuery.safeParse({ from: '2026-10-01', to: '2026-10-31' }).success).toBe(
      true,
    );
    expect(ExpenseReportQuery.safeParse({ from: '2026-10-01' }).success).toBe(false);
    expect(ExpenseReportQuery.safeParse({ from: '2026-10-02', to: '2026-10-01' }).success).toBe(
      false,
    );
    expect(
      ExpenseReport.safeParse({
        from: '2026-10-01',
        to: '2026-10-31',
        items: [{ category_id: CATEGORY, category_name: 'Rent', count: 2, total: '3000.00' }],
        count: 2,
        total: '3000.00',
      }).success,
    ).toBe(true);
    expect(errorCodeHttpStatus.EXPENSE_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.EXPENSE_CATEGORY_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.EXPENSE_CATEGORY_NAME_TAKEN).toBe(409);
    expect(errorCodeHttpStatus.EXPENSE_CATEGORY_ARCHIVED).toBe(409);
    expect(errorCodeHttpStatus.EXPENSE_ALREADY_REVERSED).toBe(409);
  });
});
