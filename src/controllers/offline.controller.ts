import type { Request, Response } from 'express';
import {
  OfflineImportBody,
  OfflineLeaseBody,
  OfflineResolveBody,
  OfflineSaleIdParams,
  OfflineSaleListQuery,
  OfflineSettingsBody,
  OfflineSyncBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as offline from '../services/offline.service';

export async function lease(req: Request, res: Response) {
  res.json(await offline.lease(getCtx(req), OfflineLeaseBody.parse(req.body)));
}
export async function sync(req: Request, res: Response) {
  res.json(await offline.sync(getCtx(req), OfflineSyncBody.parse(req.body)));
}
export async function importItems(req: Request, res: Response) {
  res.json(await offline.importItems(getCtx(req), OfflineImportBody.parse(req.body)));
}
export async function list(req: Request, res: Response) {
  res.json(await offline.list(getCtx(req), OfflineSaleListQuery.parse(req.query)));
}
export async function get(req: Request, res: Response) {
  res.json(await offline.get(getCtx(req), OfflineSaleIdParams.parse(req.params).id));
}
export async function resolve(req: Request, res: Response) {
  res.json(
    await offline.resolve(
      getCtx(req),
      OfflineSaleIdParams.parse(req.params).id,
      OfflineResolveBody.parse(req.body),
    ),
  );
}
export async function getSettings(req: Request, res: Response) {
  res.json(await offline.getSettings(getCtx(req)));
}
export async function setSettings(req: Request, res: Response) {
  res.json(await offline.setSettings(getCtx(req), OfflineSettingsBody.parse(req.body)));
}
/** GET /api/health: the POS's connectivity check. No database, no session. */
export async function health(_req: Request, res: Response) {
  res.json(await Promise.resolve({ ok: true }));
}
