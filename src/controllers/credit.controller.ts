import type { Request, Response } from 'express';
import {
  CreditCheckQuery,
  CreditExceptionDecideBody,
  CreditExceptionIdParams,
  type CreditExceptionListQuery,
  CreditExceptionRequestBody,
  CreditLimitBody,
  CustomerIdParams,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/credit.service';

const customerId = (req: Request) => CustomerIdParams.parse({ id: req.params.id }).id;
const exceptionId = (req: Request) => CreditExceptionIdParams.parse(req.params).id;

export async function profile(req: Request, res: Response) {
  res.json(await service.getCreditProfile(getCtx(req), customerId(req)));
}
export async function setLimit(req: Request, res: Response) {
  res.json(
    await service.setCreditLimit(getCtx(req), customerId(req), CreditLimitBody.parse(req.body)),
  );
}
export async function check(req: Request, res: Response) {
  res.json(
    await service.getCreditCheck(getCtx(req), customerId(req), CreditCheckQuery.parse(req.query)),
  );
}
export async function requestException(req: Request, res: Response) {
  res
    .status(201)
    .json(
      await service.requestCreditException(
        getCtx(req),
        customerId(req),
        CreditExceptionRequestBody.parse(req.body),
      ),
    );
}
/** validate() already parsed the query with the contract (default filled). */
export async function list(req: Request, res: Response) {
  res.json(
    await service.listCreditExceptions(
      getCtx(req),
      req.query as unknown as CreditExceptionListQuery,
    ),
  );
}
export async function get(req: Request, res: Response) {
  res.json(await service.getCreditException(getCtx(req), exceptionId(req)));
}
export async function decide(req: Request, res: Response) {
  res.json(
    await service.decideCreditException(
      getCtx(req),
      exceptionId(req),
      CreditExceptionDecideBody.parse(req.body),
    ),
  );
}
export async function cancel(req: Request, res: Response) {
  res.json(await service.cancelCreditException(getCtx(req), exceptionId(req)));
}
