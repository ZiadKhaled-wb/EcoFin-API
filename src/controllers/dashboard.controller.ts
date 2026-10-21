import type { Request, Response } from 'express';
import { DashboardQuery } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/dashboard.service';

export async function get(req: Request, res: Response) {
  res.json(await service.getOwnerDashboard(getCtx(req), DashboardQuery.parse(req.query)));
}
