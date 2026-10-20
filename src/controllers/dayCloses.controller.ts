import type { Request, Response } from 'express';
import {
  CloseDayBody,
  DayCloseIdParams,
  DayCloseListQuery,
  DayClosePreviewQuery,
  ReopenDayBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/dayCloses.service';

export async function list(req: Request, res: Response) {
  res.json(await service.listDayCloses(getCtx(req), DayCloseListQuery.parse(req.query)));
}

export async function preview(req: Request, res: Response) {
  res.json(await service.getPreview(getCtx(req), DayClosePreviewQuery.parse(req.query)));
}

export async function alerts(req: Request, res: Response) {
  res.json(await service.getAlerts(getCtx(req)));
}

export async function get(req: Request, res: Response) {
  const { id } = DayCloseIdParams.parse(req.params);
  res.json(await service.getDayClose(getCtx(req), id));
}

export async function close(req: Request, res: Response) {
  res.status(201).json(await service.closeDay(getCtx(req), CloseDayBody.parse(req.body)));
}

export async function reopen(req: Request, res: Response) {
  const { id } = DayCloseIdParams.parse(req.params);
  res.json(await service.reopenDay(getCtx(req), id, ReopenDayBody.parse(req.body)));
}
