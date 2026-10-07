import type { Request, Response } from 'express';
import { InstallmentPolicyBody, ShopSettingsUpdateBody } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/settings.service';

export async function get(req: Request, res: Response) {
  res.json(await service.getSettings(getCtx(req)));
}
export async function update(req: Request, res: Response) {
  res.json(await service.updateSettings(getCtx(req), ShopSettingsUpdateBody.parse(req.body)));
}
export async function listPolicies(req: Request, res: Response) {
  res.json(await service.listPolicies(getCtx(req)));
}
export async function publishPolicy(req: Request, res: Response) {
  res
    .status(201)
    .json(await service.publishPolicy(getCtx(req), InstallmentPolicyBody.parse(req.body)));
}
