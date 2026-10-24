import type { Request, Response } from 'express';
import {
  CancelSalesOrderBody,
  CreateSalesOrderBody,
  IdempotencyKeyHeader,
  LinkOrderLineBody,
  OrderDepositBody,
  OrderFromQuotationBody,
  OrderFromQuotationParams,
  ReserveOrderLineBody,
  SalesOrderIdParams,
  SalesOrderLineParams,
  SalesOrderListQuery,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import { AppError, safeMessage } from '../utils/errors';
import * as service from '../services/salesOrders.service';
const id = (req: Request) => SalesOrderIdParams.parse(req.params).id;
const keyOf = (req: Request) => IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
function linesInvalid(): never {
  throw new AppError(safeMessage('ORDER_LINES_INVALID'), 'ORDER_LINES_INVALID');
}
export async function list(req: Request, res: Response) {
  res.json(await service.list(getCtx(req), SalesOrderListQuery.parse(req.query)));
}
export async function get(req: Request, res: Response) {
  res.json(await service.get(getCtx(req), id(req)));
}
export async function create(req: Request, res: Response) {
  const key = keyOf(req);
  const body = CreateSalesOrderBody.safeParse(req.body);
  if (!body.success) {
    if (body.error.issues.some((i) => i.path[0] === 'lines')) linesInvalid();
    throw body.error;
  }
  res.status(201).json(await service.create(getCtx(req), body.data, key));
}
export async function fromQuotation(req: Request, res: Response) {
  const quotationId = OrderFromQuotationParams.parse(req.params).id;
  const key = keyOf(req);
  const body = OrderFromQuotationBody.safeParse(req.body);
  if (!body.success) {
    if (body.error.issues.some((i) => i.path[0] === 'line_options')) linesInvalid();
    throw body.error;
  }
  res.status(201).json(await service.fromQuotation(getCtx(req), quotationId, body.data, key));
}
export async function deposit(req: Request, res: Response) {
  const orderId = id(req);
  const key = keyOf(req);
  res.json(await service.deposit(getCtx(req), orderId, OrderDepositBody.parse(req.body), key));
}
export async function cancel(req: Request, res: Response) {
  const orderId = id(req);
  const key = keyOf(req);
  const body = CancelSalesOrderBody.safeParse(req.body);
  if (!body.success) {
    if (body.error.issues.some((i) => i.path[0] === 'reason'))
      throw new AppError(safeMessage('REASON_REQUIRED'), 'REASON_REQUIRED');
    throw body.error;
  }
  res.json(await service.cancel(getCtx(req), orderId, body.data, key));
}
export async function reserve(req: Request, res: Response) {
  const p = SalesOrderLineParams.parse(req.params);
  const body = ReserveOrderLineBody.parse(req.body ?? {});
  res.json(await service.reserve(getCtx(req), p.id, p.lineId, body.unit_ids));
}
export async function linkPo(req: Request, res: Response) {
  const p = SalesOrderLineParams.parse(req.params);
  const body = LinkOrderLineBody.parse(req.body);
  res.json(await service.linkPo(getCtx(req), p.id, p.lineId, body.po_line_id));
}
