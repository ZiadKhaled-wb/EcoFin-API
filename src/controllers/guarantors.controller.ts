import type { Request, Response } from 'express';
import {
  CustomerGuarantorLinkBody,
  CustomerGuarantorParams,
  CustomerGuarantorRelationBody,
  CustomerIdParams,
  GuarantorCreateBody,
  GuarantorIdParams,
  type GuarantorListQuery,
  GuarantorRequirementQuery,
  GuarantorUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/guarantors.service';

const id = (req: Request) => GuarantorIdParams.parse(req.params).id;
const customerId = (req: Request) => CustomerIdParams.parse({ id: req.params.id }).id;
const links = (req: Request) => CustomerGuarantorParams.parse(req.params);

/** validate() already parsed the query with the contract (defaults filled). */
export async function list(req: Request, res: Response) {
  res.json(await service.listGuarantors(getCtx(req), req.query as unknown as GuarantorListQuery));
}
export async function get(req: Request, res: Response) {
  res.json(await service.getGuarantor(getCtx(req), id(req)));
}
export async function create(req: Request, res: Response) {
  res
    .status(201)
    .json(await service.createGuarantor(getCtx(req), GuarantorCreateBody.parse(req.body)));
}
export async function update(req: Request, res: Response) {
  res.json(
    await service.updateGuarantor(getCtx(req), id(req), GuarantorUpdateBody.parse(req.body)),
  );
}
export async function archive(req: Request, res: Response) {
  res.json(await service.setGuarantorArchived(getCtx(req), id(req), true));
}
export async function restore(req: Request, res: Response) {
  res.json(await service.setGuarantorArchived(getCtx(req), id(req), false));
}

export async function listForCustomer(req: Request, res: Response) {
  res.json(await service.listCustomerGuarantors(getCtx(req), customerId(req)));
}
export async function link(req: Request, res: Response) {
  res
    .status(201)
    .json(
      await service.linkCustomerGuarantor(
        getCtx(req),
        customerId(req),
        CustomerGuarantorLinkBody.parse(req.body),
      ),
    );
}
export async function setRelation(req: Request, res: Response) {
  const p = links(req);
  res.json(
    await service.setCustomerGuarantorRelation(
      getCtx(req),
      p.id,
      p.guarantorId,
      CustomerGuarantorRelationBody.parse(req.body),
    ),
  );
}
export async function unlink(req: Request, res: Response) {
  const p = links(req);
  res.json(await service.unlinkCustomerGuarantor(getCtx(req), p.id, p.guarantorId));
}
export async function requirement(req: Request, res: Response) {
  res.json(
    await service.getGuarantorRequirement(
      getCtx(req),
      customerId(req),
      GuarantorRequirementQuery.parse(req.query),
    ),
  );
}
