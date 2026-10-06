import type { Request, Response } from 'express';
import {
  AdminCreateShopBody,
  AdminShopsQuery,
  AdminShopId,
  AdminShopStatusBody,
} from '@ziadkhaled-wb/contracts';
import { adminDbFor } from '../middleware/superAdmin';
import * as admin from '../services/admin.service';
export async function plans(req: Request, res: Response) {
  res.json(await admin.listPlans(adminDbFor(req)));
}
export async function shops(req: Request, res: Response) {
  res.json(await admin.listShops(adminDbFor(req), AdminShopsQuery.parse(req.query)));
}
export async function create(req: Request, res: Response) {
  res
    .status(201)
    .json(await admin.provisionShop(adminDbFor(req), AdminCreateShopBody.parse(req.body)));
}
export async function status(req: Request, res: Response) {
  res.json(
    await admin.setShopStatus(
      adminDbFor(req),
      AdminShopId.parse(req.params).id,
      AdminShopStatusBody.parse(req.body),
    ),
  );
}
export async function resend(req: Request, res: Response) {
  res.json(await admin.resendOwnerInvite(adminDbFor(req), AdminShopId.parse(req.params).id));
}
