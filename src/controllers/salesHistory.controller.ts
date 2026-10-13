import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  SaleIdParams,
  SalesHistoryQuery,
  SaleVoidBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as history from '../services/salesHistory.service';
export async function list(req: Request, res: Response) {
  res.json(await history.searchSales(getCtx(req), SalesHistoryQuery.parse(req.query)));
}
export async function voidSale(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res
    .status(201)
    .json(
      await history.voidSale(
        getCtx(req),
        SaleIdParams.parse(req.params).id,
        SaleVoidBody.parse(req.body).reason,
        key,
      ),
    );
}
export async function recordReceiptPrint(req: Request, res: Response) {
  res
    .status(201)
    .json(await history.recordReceiptPrint(getCtx(req), SaleIdParams.parse(req.params).id));
}
