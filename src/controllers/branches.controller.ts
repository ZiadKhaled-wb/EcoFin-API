import type { Request, Response } from 'express';
import {
  BranchCreateBody,
  BranchUpdateBody,
  BranchDeactivateBody,
  BranchIdParams,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/branches.service';
const id = (req: Request) => BranchIdParams.parse(req.params).id;
export async function list(req: Request, res: Response) {
  res.json(await service.listBranches(getCtx(req)));
}
export async function manage(req: Request, res: Response) {
  res.json(await service.manageBranches(getCtx(req)));
}
export async function detail(req: Request, res: Response) {
  res.json(await service.branchDetail(getCtx(req), id(req)));
}
export async function create(req: Request, res: Response) {
  res.status(201).json(await service.createBranch(getCtx(req), BranchCreateBody.parse(req.body)));
}
export async function update(req: Request, res: Response) {
  res.json(await service.updateBranch(getCtx(req), id(req), BranchUpdateBody.parse(req.body)));
}
export async function check(req: Request, res: Response) {
  res.json(await service.deactivationCheck(getCtx(req), id(req)));
}
export async function deactivate(req: Request, res: Response) {
  const body = BranchDeactivateBody.parse(req.body);
  res.json(await service.setBranchActive(getCtx(req), id(req), false, body.reason, body.confirm));
}
export async function reactivate(req: Request, res: Response) {
  res.json(await service.setBranchActive(getCtx(req), id(req), true));
}
