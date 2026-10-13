import type { Request, Response } from 'express';
import {
  IdempotencyKeyHeader,
  WarrantyLookupQuery,
  WarrantyClaimsQuery,
  WarrantyClaimIdParams,
  OpenWarrantyClaimBody,
  MoveWarrantyClaimBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import { BadRequest } from '../utils/errors';
import * as warranty from '../services/warranty.service';
const id = (req: Request) => WarrantyClaimIdParams.parse(req.params).id;
export async function lookup(req: Request, res: Response) {
  if (
    ['serial', 'phone', 'sale_number'].filter(
      (k) => typeof req.query[k] === 'string' && String(req.query[k]).trim(),
    ).length !== 1
  )
    throw BadRequest('Use exactly one lookup key.', 'LOOKUP_ONE_KEY');
  res.json(await warranty.lookup(getCtx(req), WarrantyLookupQuery.parse(req.query)));
}
export async function list(req: Request, res: Response) {
  res.json(await warranty.list(getCtx(req), WarrantyClaimsQuery.parse(req.query)));
}
export async function get(req: Request, res: Response) {
  res.json(await warranty.get(getCtx(req), id(req)));
}
export async function open(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res
    .status(201)
    .json(await warranty.open(getCtx(req), OpenWarrantyClaimBody.parse(req.body), key));
}
export async function move(req: Request, res: Response) {
  res.json(await warranty.move(getCtx(req), id(req), MoveWarrantyClaimBody.parse(req.body)));
}
export async function refund(req: Request, res: Response) {
  res.json(await warranty.refund(getCtx(req), id(req)));
}
