import type { Request, Response } from 'express';
import { ReceivablesQuery, SalesReportQuery } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/reports.service';

export async function sales(req: Request, res: Response) {
  res.json(await service.getSalesReport(getCtx(req), SalesReportQuery.parse(req.query)));
}

export async function receivables(req: Request, res: Response) {
  res.json(await service.getReceivablesReport(getCtx(req), ReceivablesQuery.parse(req.query)));
}
