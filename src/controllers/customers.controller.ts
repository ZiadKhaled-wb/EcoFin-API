import type { Request, Response } from 'express';
import {
  CustomerCreateBody,
  CustomerIdParams,
  type CustomerListQuery,
  CustomerStatusBody,
  CustomerUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/customers.service';
const id = (req: Request) => CustomerIdParams.parse(req.params).id;
/** validate() already parsed the query with the contract (defaults filled). */
export async function list(req: Request, res: Response) {
  res.json(await service.listCustomers(getCtx(req), req.query as unknown as CustomerListQuery));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getCustomer(getCtx(req), id(req)));
}
export async function create(req: Request, res: Response) {
  res
    .status(201)
    .json(await service.createCustomer(getCtx(req), CustomerCreateBody.parse(req.body)));
}
export async function update(req: Request, res: Response) {
  res.json(await service.updateCustomer(getCtx(req), id(req), CustomerUpdateBody.parse(req.body)));
}
export async function setStatus(req: Request, res: Response) {
  res.json(
    await service.setCustomerStatus(getCtx(req), id(req), CustomerStatusBody.parse(req.body)),
  );
}
