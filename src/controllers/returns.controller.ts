import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  ReturnIdParams,
  SaleIdParams,
  SalesReturnCreateBody,
  SalesReturnListQuery,
  SalesReturnQuoteBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as returns from '../services/returns.service';

export async function returnable(req: Request, res: Response) {
  res.json(await returns.getReturnable(getCtx(req), SaleIdParams.parse(req.params).id));
}
export async function quote(req: Request, res: Response) {
  res.json(await returns.quote(getCtx(req), SalesReturnQuoteBody.parse(req.body)));
}
export async function post(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  const result = await returns.post(getCtx(req), SalesReturnCreateBody.parse(req.body), key);
  res.status(result.replayed ? 200 : 201).json(result);
}
export async function list(req: Request, res: Response) {
  res.json(await returns.list(getCtx(req), SalesReturnListQuery.parse(req.query)));
}
export async function get(req: Request, res: Response) {
  res.json(await returns.get(getCtx(req), ReturnIdParams.parse(req.params).id));
}
export async function recordReceiptPrint(req: Request, res: Response) {
  res
    .status(201)
    .json(await returns.recordReceiptPrint(getCtx(req), ReturnIdParams.parse(req.params).id));
}
