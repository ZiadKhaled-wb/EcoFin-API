import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  SaleCreateBody,
  SaleIdParams,
  SaleQuoteBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/sales.service';
export async function quote(req: Request, res: Response) {
  res.json(await service.quoteSale(getCtx(req), SaleQuoteBody.parse(req.body)));
}
export async function create(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res.status(201).json(await service.postSale(getCtx(req), SaleCreateBody.parse(req.body), key));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getSale(getCtx(req), SaleIdParams.parse(req.params).id));
}
