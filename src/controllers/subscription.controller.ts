import type { Request, Response } from 'express';
import {
  AdminShopId,
  SubscriptionPlanBody,
  SubscriptionDatesBody,
  SubscriptionPaymentBody,
  SubscriptionPaymentHeader,
} from '@ziadkhaled-wb/contracts';
import { adminDbFor } from '../middleware/superAdmin';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/subscription.service';
export async function status(req: Request, res: Response) {
  res.json(await service.getSubscriptionStatus(getCtx(req).db));
}
export async function adminStatus(req: Request, res: Response) {
  res.json(await service.getAdminSubscription(adminDbFor(req), AdminShopId.parse(req.params).id));
}
export async function plan(req: Request, res: Response) {
  res.json(
    await service.changePlan(
      adminDbFor(req),
      AdminShopId.parse(req.params).id,
      SubscriptionPlanBody.parse(req.body),
    ),
  );
}
export async function dates(req: Request, res: Response) {
  res.json(
    await service.setDates(
      adminDbFor(req),
      AdminShopId.parse(req.params).id,
      SubscriptionDatesBody.parse(req.body),
    ),
  );
}
export async function payment(req: Request, res: Response) {
  const key = SubscriptionPaymentHeader.parse(req.headers)['idempotency-key'];
  res
    .status(201)
    .json(
      await service.recordPayment(
        adminDbFor(req),
        AdminShopId.parse(req.params).id,
        SubscriptionPaymentBody.parse(req.body),
        key,
      ),
    );
}
