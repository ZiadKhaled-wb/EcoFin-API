import type { Request, Response } from 'express';
import {
  SupplierCreateBody,
  SupplierIdParams,
  type SupplierListQuery,
  SupplierStatementQuery,
  SupplierUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/suppliers.service';
const id = (req: Request) => SupplierIdParams.parse(req.params).id;
/** validate() already parsed the query with the contract (defaults filled). */
export async function list(req: Request, res: Response) {
  res.json(await service.listSuppliers(getCtx(req), req.query as unknown as SupplierListQuery));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getSupplier(getCtx(req), id(req)));
}
export async function statement(req: Request, res: Response) {
  res.json(
    await service.getSupplierStatement(
      getCtx(req),
      id(req),
      SupplierStatementQuery.parse(req.query),
    ),
  );
}
export async function create(req: Request, res: Response) {
  res
    .status(201)
    .json(await service.createSupplier(getCtx(req), SupplierCreateBody.parse(req.body)));
}
export async function update(req: Request, res: Response) {
  res.json(await service.updateSupplier(getCtx(req), id(req), SupplierUpdateBody.parse(req.body)));
}
export async function archive(req: Request, res: Response) {
  res.json(await service.setSupplierArchived(getCtx(req), id(req), true));
}
export async function restore(req: Request, res: Response) {
  res.json(await service.setSupplierArchived(getCtx(req), id(req), false));
}
