import type { Request, Response } from 'express';
import { ExportIdParams, IdempotencyKeyHeader, StartExportBody } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/exports.service';

const id = (req: Request) => ExportIdParams.parse(req.params).id;

export async function start(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res
    .status(202)
    .json(await service.startExport(getCtx(req), StartExportBody.parse(req.body), key));
}
export async function list(req: Request, res: Response) {
  res.json(await service.listExports(getCtx(req)));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getExport(getCtx(req), id(req)));
}
export async function cancel(req: Request, res: Response) {
  res.json(await service.cancelExport(getCtx(req), id(req)));
}
