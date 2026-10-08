import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  UnitIdParams,
  type UnitFindQuery,
  type UnitRegisterBody,
  type UnitSearchQuery,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/units.service';
/** validate() already parsed the query, params and body with the contract. */
export async function search(req: Request, res: Response) {
  res.json(await service.searchUnits(getCtx(req), req.query as unknown as UnitSearchQuery));
}
export async function find(req: Request, res: Response) {
  const { serial } = req.query as unknown as UnitFindQuery;
  res.json(await service.getUnit(getCtx(req), { serial }));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getUnit(getCtx(req), { id: UnitIdParams.parse(req.params).id }));
}
export async function register(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res.status(201).json(await service.registerUnits(getCtx(req), req.body as UnitRegisterBody, key));
}
