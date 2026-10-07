import type { Request, Response } from 'express';
import { TaxClassCreateBody, TaxClassIdParams, TaxClassUpdateBody } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/taxClasses.service';

const id = (req: Request) => TaxClassIdParams.parse(req.params).id;
export async function list(req: Request, res: Response) {
  res.json(await service.listTaxClasses(getCtx(req)));
}
export async function create(req: Request, res: Response) {
  res
    .status(201)
    .json(await service.createTaxClass(getCtx(req), TaxClassCreateBody.parse(req.body)));
}
export async function update(req: Request, res: Response) {
  res.json(await service.updateTaxClass(getCtx(req), id(req), TaxClassUpdateBody.parse(req.body)));
}
export async function archive(req: Request, res: Response) {
  res.json(await service.setTaxClassArchived(getCtx(req), id(req), true));
}
export async function restore(req: Request, res: Response) {
  res.json(await service.setTaxClassArchived(getCtx(req), id(req), false));
}
