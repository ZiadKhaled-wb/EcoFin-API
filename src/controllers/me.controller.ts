// server/src/controllers/me.controller.ts
import type { Request, Response } from 'express';
import type { MePermissionsResponse } from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import { getMyPermissions } from '../services/permissions.service';

/** GET /api/me/permissions: the caller's effective permission keys and branch scope (F06). */
export async function permissions(req: Request, res: Response) {
  const result: MePermissionsResponse = await getMyPermissions(getCtx(req));
  res.json(result);
}
