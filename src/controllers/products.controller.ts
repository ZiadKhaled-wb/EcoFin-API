import type { Request, Response } from 'express';
import {
  ProductCreateBody,
  ProductIdParams,
  type ProductListQuery,
  type ProductLookupQuery,
  type ProductUnitsQuery,
  ProductUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/products.service';
const id = (req: Request) => ProductIdParams.parse(req.params).id;
/** validate() already parsed the query with the contract (defaults filled, flags as booleans). */
export async function list(req: Request, res: Response) {
  res.json(await service.listProducts(getCtx(req), req.query as unknown as ProductListQuery));
}
export async function lookup(req: Request, res: Response) {
  const { code } = req.query as unknown as ProductLookupQuery;
  res.json(await service.lookupProduct(getCtx(req), code));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getProduct(getCtx(req), id(req)));
}
export async function create(req: Request, res: Response) {
  res.status(201).json(await service.createProduct(getCtx(req), ProductCreateBody.parse(req.body)));
}
export async function update(req: Request, res: Response) {
  res.json(await service.updateProduct(getCtx(req), id(req), ProductUpdateBody.parse(req.body)));
}
export async function archive(req: Request, res: Response) {
  res.json(await service.setProductArchived(getCtx(req), id(req), true));
}
export async function restore(req: Request, res: Response) {
  res.json(await service.setProductArchived(getCtx(req), id(req), false));
}
export async function units(req: Request, res: Response) {
  res.json(
    await service.listProductUnits(getCtx(req), id(req), req.query as unknown as ProductUnitsQuery),
  );
}
