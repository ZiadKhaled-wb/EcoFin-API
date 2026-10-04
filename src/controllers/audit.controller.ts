// server/src/controllers/audit.controller.ts
import type { Request, Response } from 'express';
import type { AuditSearchQuery } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import { searchAudit } from '../services/audit.service';

/** GET /api/audit: validate() already parsed the query with the contract (defaults filled). */
export async function search(req: Request, res: Response) {
  res.json(await searchAudit(getCtx(req), req.query as unknown as AuditSearchQuery));
}
