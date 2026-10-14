import type { Request, Response } from 'express';
import {
  FiscalAssignDeviceBody,
  FiscalDaySummaryQuery,
  FiscalListQuery,
  FiscalRetryManyBody,
  FiscalSubmissionIdParams,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/fiscal.service';

const idOf = (req: Request): string => FiscalSubmissionIdParams.parse(req.params).id;

export async function list(req: Request, res: Response) {
  res.json(await service.list(getCtx(req), FiscalListQuery.parse(req.query)));
}
export async function summary(req: Request, res: Response) {
  res.json(await service.alertSummary(getCtx(req)));
}
export async function daySummary(req: Request, res: Response) {
  res.json(await service.daySummary(getCtx(req), FiscalDaySummaryQuery.parse(req.query)));
}
export async function details(req: Request, res: Response) {
  res.json(await service.details(getCtx(req), idOf(req)));
}
export async function retry(req: Request, res: Response) {
  res.json(await service.retry(getCtx(req), idOf(req)));
}
export async function correct(req: Request, res: Response) {
  res.status(202).json(await service.correct(getCtx(req), idOf(req)));
}
export async function assignDevice(req: Request, res: Response) {
  res.json(
    await service.assignDevice(
      getCtx(req),
      idOf(req),
      FiscalAssignDeviceBody.parse(req.body).device_id,
    ),
  );
}
export async function checkNow(req: Request, res: Response) {
  res.status(202).json(await service.checkNow(getCtx(req), idOf(req)));
}
export async function retryMany(req: Request, res: Response) {
  res.json(await service.retryMany(getCtx(req), FiscalRetryManyBody.parse(req.body).ids));
}
