import type { Request, Response } from 'express';
import type { StockListQuery, StockMovementsQuery } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/stock.service';
/** validate() already parsed the query with the contract (defaults filled, flags as booleans). */
export async function list(req: Request, res: Response) {
  res.json(await service.listStock(getCtx(req), req.query as unknown as StockListQuery));
}
export async function movements(req: Request, res: Response) {
  res.json(
    await service.listStockMovements(getCtx(req), req.query as unknown as StockMovementsQuery),
  );
}
