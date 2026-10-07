import type { Request, Response } from 'express';
import {
  InstallmentPolicyBody,
  ShopProfileUpdateBody,
  ShopSettingsUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/settings.service';

export async function get(req: Request, res: Response) {
  res.json(await service.getSettings(getCtx(req)));
}
export async function update(req: Request, res: Response) {
  res.json(await service.updateSettings(getCtx(req), ShopSettingsUpdateBody.parse(req.body)));
}
export async function getProfile(req: Request, res: Response) {
  res.json(await service.getProfile(getCtx(req)));
}
export async function updateProfile(req: Request, res: Response) {
  res.json(await service.updateProfile(getCtx(req), ShopProfileUpdateBody.parse(req.body)));
}
export async function listPolicies(req: Request, res: Response) {
  res.json(await service.listPolicies(getCtx(req)));
}
export async function publishPolicy(req: Request, res: Response) {
  res
    .status(201)
    .json(await service.publishPolicy(getCtx(req), InstallmentPolicyBody.parse(req.body)));
}
