import type { Request, Response } from 'express';
import {
  ContractIdParams,
  IdempotencyKeyHeader,
  InstallmentPreviewBody,
  InstallmentSaleBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/installments.service';

export async function preview(req: Request, res: Response) {
  res.json(
    await service.previewInstallmentTerms(getCtx(req), InstallmentPreviewBody.parse(req.body)),
  );
}

export async function createSale(req: Request, res: Response) {
  const key = IdempotencyKeyHeader.parse(req.headers)['idempotency-key'];
  res
    .status(201)
    .json(await service.postInstallmentSale(getCtx(req), InstallmentSaleBody.parse(req.body), key));
}

export async function getContract(req: Request, res: Response) {
  res.json(await service.getContract(getCtx(req), ContractIdParams.parse(req.params).id));
}
