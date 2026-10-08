import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  StockDocumentIdParams,
  type StockAdjustmentCreateBody,
  type StockAdjustmentListQuery,
  type StockCountCreateBody,
  type StockCountDetailQuery,
  type StockCountLinesBody,
  type StockCountListQuery,
  type StockCountPostBody,
  type StockCountScanBody,
  type StockListQuery,
  type StockMovementExportBody,
  type StockMovementsQuery,
  type StockTransferCreateBody,
  type StockTransferListQuery,
  type StockTransferReceiveBody,
  type StockTransferUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/stock.service';
/** validate() already parsed the query, params and body with the contract (defaults filled). */
export async function list(req: Request, res: Response) {
  res.json(await service.listStock(getCtx(req), req.query as unknown as StockListQuery));
}
export async function movements(req: Request, res: Response) {
  res.json(
    await service.listStockMovements(getCtx(req), req.query as unknown as StockMovementsQuery),
  );
}
export async function exportMovements(req: Request, res: Response) {
  res.json(await service.exportStockMovements(getCtx(req), req.body as StockMovementExportBody));
}
const idOf = (req: Request) => StockDocumentIdParams.parse(req.params).id;
/** Stock writes take the `Idempotency-Key` header (8-128 characters); missing = 400. */
const keyOf = (req: Request) => IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
export async function listAdjustments(req: Request, res: Response) {
  res.json(
    await service.listAdjustments(getCtx(req), req.query as unknown as StockAdjustmentListQuery),
  );
}
export async function getAdjustment(req: Request, res: Response) {
  res.json(await service.getAdjustment(getCtx(req), idOf(req)));
}
export async function postAdjustment(req: Request, res: Response) {
  const key = keyOf(req);
  res
    .status(201)
    .json(await service.postAdjustment(getCtx(req), req.body as StockAdjustmentCreateBody, key));
}
export async function listCounts(req: Request, res: Response) {
  res.json(await service.listCounts(getCtx(req), req.query as unknown as StockCountListQuery));
}
export async function createCount(req: Request, res: Response) {
  const key = keyOf(req);
  res
    .status(201)
    .json(await service.createCount(getCtx(req), req.body as StockCountCreateBody, key));
}
export async function getCount(req: Request, res: Response) {
  res.json(
    await service.getCount(getCtx(req), idOf(req), req.query as unknown as StockCountDetailQuery),
  );
}
export async function saveCountLines(req: Request, res: Response) {
  res.json(await service.saveCountLines(getCtx(req), idOf(req), req.body as StockCountLinesBody));
}
export async function scanCount(req: Request, res: Response) {
  res.json(await service.scanCount(getCtx(req), idOf(req), (req.body as StockCountScanBody).code));
}
export async function postCount(req: Request, res: Response) {
  const key = keyOf(req);
  res.json(await service.postCount(getCtx(req), idOf(req), req.body as StockCountPostBody, key));
}
export async function cancelCount(req: Request, res: Response) {
  res.json(await service.cancelCount(getCtx(req), idOf(req)));
}
export async function listTransfers(req: Request, res: Response) {
  res.json(
    await service.listTransfers(getCtx(req), req.query as unknown as StockTransferListQuery),
  );
}
export async function getTransfer(req: Request, res: Response) {
  res.json(await service.getTransfer(getCtx(req), idOf(req)));
}
export async function createTransfer(req: Request, res: Response) {
  const key = keyOf(req);
  res
    .status(201)
    .json(await service.createTransfer(getCtx(req), req.body as StockTransferCreateBody, key));
}
export async function updateTransfer(req: Request, res: Response) {
  res.json(
    await service.updateTransfer(getCtx(req), idOf(req), req.body as StockTransferUpdateBody),
  );
}
export async function sendTransfer(req: Request, res: Response) {
  res.json(await service.transferAction(getCtx(req), idOf(req), 'send'));
}
export async function cancelTransfer(req: Request, res: Response) {
  res.json(await service.transferAction(getCtx(req), idOf(req), 'cancel'));
}
export async function receiveTransfer(req: Request, res: Response) {
  res.json(
    await service.receiveTransfer(getCtx(req), idOf(req), req.body as StockTransferReceiveBody),
  );
}
export async function transferDestinations(req: Request, res: Response) {
  res.json(await service.listTransferDestinations(getCtx(req)));
}
