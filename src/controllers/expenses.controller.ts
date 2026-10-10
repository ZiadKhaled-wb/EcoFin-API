import type { Request, Response } from 'express';
import {
  ExpenseCategoryBody,
  ExpenseCategoryIdParams,
  ExpenseCategoryListQuery,
  ExpenseCreateBody,
  ExpenseIdParams,
  ExpenseListQuery,
  ExpenseReportQuery,
  ExpenseReverseBody,
  IdempotencyKeyHeader,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/expenses.service';
const categoryId = (req: Request) => ExpenseCategoryIdParams.parse(req.params).id;
const id = (req: Request) => ExpenseIdParams.parse(req.params).id;
const keyOf = (req: Request) => IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
export async function listCategories(req: Request, res: Response) {
  const { include_archived } = ExpenseCategoryListQuery.parse(req.query);
  res.json(await service.listExpenseCategories(getCtx(req), include_archived));
}
export async function createCategory(req: Request, res: Response) {
  const { name } = ExpenseCategoryBody.parse(req.body);
  res.status(201).json(await service.createExpenseCategory(getCtx(req), name));
}
export async function renameCategory(req: Request, res: Response) {
  const { name } = ExpenseCategoryBody.parse(req.body);
  res.json(await service.renameExpenseCategory(getCtx(req), categoryId(req), name));
}
export async function archiveCategory(req: Request, res: Response) {
  res.json(await service.setExpenseCategoryArchived(getCtx(req), categoryId(req), true));
}
export async function restoreCategory(req: Request, res: Response) {
  res.json(await service.setExpenseCategoryArchived(getCtx(req), categoryId(req), false));
}
export async function list(req: Request, res: Response) {
  res.json(await service.listExpenses(getCtx(req), ExpenseListQuery.parse(req.query)));
}
export async function report(req: Request, res: Response) {
  res.json(await service.expenseReport(getCtx(req), ExpenseReportQuery.parse(req.query)));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getExpense(getCtx(req), id(req)));
}
export async function create(req: Request, res: Response) {
  const key = keyOf(req);
  res
    .status(201)
    .json(await service.postExpense(getCtx(req), ExpenseCreateBody.parse(req.body), key));
}
export async function reverse(req: Request, res: Response) {
  const key = keyOf(req);
  res.json(
    await service.reverseExpense(getCtx(req), id(req), ExpenseReverseBody.parse(req.body), key),
  );
}
