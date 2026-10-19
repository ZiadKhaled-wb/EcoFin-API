import type { Request, Response } from 'express';
import { ContractDocumentPrintBody, ContractIdParams } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/contractDocuments.service';

export async function documents(req: Request, res: Response) {
  const { id } = ContractIdParams.parse(req.params);
  // National IDs are on this answer: no shared or browser cache may keep it.
  res.setHeader('Cache-Control', 'no-store');
  res.json(await service.getDocuments(getCtx(req), id));
}

export async function print(req: Request, res: Response) {
  const { id } = ContractIdParams.parse(req.params);
  const { document } = ContractDocumentPrintBody.parse(req.body);
  res.json(await service.recordPrint(getCtx(req), id, document));
}
