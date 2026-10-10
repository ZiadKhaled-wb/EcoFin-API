import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  ShiftCashBody,
  ShiftCloseBody,
  ShiftIdParams,
  ShiftListQuery,
  ShiftOpenBody,
  ShiftVaultQuery,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/shifts.service';
const id = (req: Request) => ShiftIdParams.parse(req.params).id;
const keyOf = (req: Request) => IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
export async function list(req: Request, res: Response) {
  res.json(await service.listShifts(getCtx(req), ShiftListQuery.parse(req.query)));
}
export async function current(req: Request, res: Response) {
  res.json(await service.getCurrentShift(getCtx(req)));
}
export async function vaults(req: Request, res: Response) {
  const { branch_id } = ShiftVaultQuery.parse(req.query);
  res.json(await service.listShiftVaults(getCtx(req), branch_id));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getShift(getCtx(req), id(req)));
}
export async function open(req: Request, res: Response) {
  const key = keyOf(req);
  res.status(201).json(await service.openShift(getCtx(req), ShiftOpenBody.parse(req.body), key));
}
export async function cash(req: Request, res: Response) {
  const key = keyOf(req);
  res.json(await service.moveShiftCash(getCtx(req), id(req), ShiftCashBody.parse(req.body), key));
}
export async function close(req: Request, res: Response) {
  res.json(await service.closeShift(getCtx(req), id(req), ShiftCloseBody.parse(req.body)));
}
