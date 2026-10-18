import type { Request, Response } from 'express';
import {
  ContractChangeListQuery,
  ContractIdParams,
  IdempotencyKeyHeader,
  ReschedulePreviewBody,
  RescheduleBody,
  SettleBody,
  WriteOffBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/contractChanges.service';

export async function settlementQuote(req: Request, res: Response) {
  const { id } = ContractIdParams.parse(req.params);
  res.json(await service.getSettlementQuote(getCtx(req), id));
}

export async function settle(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  const { id } = ContractIdParams.parse(req.params);
  res.json(await service.settleEarly(getCtx(req), id, SettleBody.parse(req.body), key));
}

export async function previewReschedule(req: Request, res: Response) {
  const { id } = ContractIdParams.parse(req.params);
  res.json(await service.previewReschedule(getCtx(req), id, ReschedulePreviewBody.parse(req.body)));
}

export async function reschedule(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  const { id } = ContractIdParams.parse(req.params);
  res.json(await service.reschedule(getCtx(req), id, RescheduleBody.parse(req.body), key));
}

export async function writeOff(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  const { id } = ContractIdParams.parse(req.params);
  res.json(await service.writeOff(getCtx(req), id, WriteOffBody.parse(req.body), key));
}

export async function history(req: Request, res: Response) {
  const { id } = ContractIdParams.parse(req.params);
  res.json(await service.getHistory(getCtx(req), id));
}

export async function list(req: Request, res: Response) {
  res.json(await service.listChanges(getCtx(req), ContractChangeListQuery.parse(req.query)));
}
