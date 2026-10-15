import type { Request, Response } from 'express';
import {
  CustomerContractParams,
  CustomerIdParams,
  CustomerStatementQuery,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/customerAccount.service';

const customerId = (req: Request) => CustomerIdParams.parse({ id: req.params.id }).id;

export async function account(req: Request, res: Response) {
  res.json(await service.getCustomerAccount(getCtx(req), customerId(req)));
}
export async function schedule(req: Request, res: Response) {
  const params = CustomerContractParams.parse(req.params);
  res.json(await service.getContractSchedule(getCtx(req), params.id, params.contractId));
}
export async function statement(req: Request, res: Response) {
  res.json(
    await service.getCustomerStatement(
      getCtx(req),
      customerId(req),
      CustomerStatementQuery.parse(req.query),
    ),
  );
}
