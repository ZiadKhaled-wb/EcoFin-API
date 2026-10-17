import type { Request, Response } from 'express';
import {
  DismissReferralBody,
  HandleWarningBody,
  LegalReferralListQuery,
  OverdueActionIdParams,
  OverdueListQuery,
  OverdueWarningListQuery,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/overdue.service';

export async function list(req: Request, res: Response) {
  res.json(await service.listOverdueContracts(getCtx(req), OverdueListQuery.parse(req.query)));
}

export async function listWarnings(req: Request, res: Response) {
  res.json(await service.listWarnings(getCtx(req), OverdueWarningListQuery.parse(req.query)));
}

export async function handleWarning(req: Request, res: Response) {
  const { id } = OverdueActionIdParams.parse(req.params);
  res.json(await service.handleWarning(getCtx(req), id, HandleWarningBody.parse(req.body)));
}

export async function listReferrals(req: Request, res: Response) {
  res.json(await service.listReferrals(getCtx(req), LegalReferralListQuery.parse(req.query)));
}

export async function dismissReferral(req: Request, res: Response) {
  const { id } = OverdueActionIdParams.parse(req.params);
  res.json(await service.dismissReferral(getCtx(req), id, DismissReferralBody.parse(req.body)));
}

export async function run(req: Request, res: Response) {
  res.json(await service.runCheck(getCtx(req)));
}
