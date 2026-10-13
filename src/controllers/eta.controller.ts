import type { Request, Response } from 'express';
import {
  DeviceEtaBody,
  DeviceIdParams,
  EtaSettingsBody,
  EtaTestBody,
  FiscalSubmissionIdParams,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/eta.service';

export async function getSettings(req: Request, res: Response) {
  res.json(await service.getSettings(getCtx(req)));
}
export async function setSettings(req: Request, res: Response) {
  res.json(await service.setSettings(getCtx(req), EtaSettingsBody.parse(req.body)));
}
export async function testConnection(req: Request, res: Response) {
  res.json(await service.testConnection(getCtx(req), EtaTestBody.parse(req.body).device_id));
}
export async function retrySubmission(req: Request, res: Response) {
  res.json(
    await service.retrySubmission(getCtx(req), FiscalSubmissionIdParams.parse(req.params).id),
  );
}
export async function listDevices(req: Request, res: Response) {
  res.json(await service.listDevices(getCtx(req)));
}
export async function setDeviceEta(req: Request, res: Response) {
  res.json(
    await service.setDeviceEta(
      getCtx(req),
      DeviceIdParams.parse(req.params).id,
      DeviceEtaBody.parse(req.body),
    ),
  );
}
