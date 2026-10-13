import type { Request, Response } from 'express';
import {
  CurrentDeviceResponse,
  DeviceActiveBody,
  DeviceCreateBody,
  DeviceIdParams,
  DevicePairBody,
  DeviceUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { getCtx } from '../middleware/requestContext';
import * as service from '../services/devices.service';

const id = (req: Request) => DeviceIdParams.parse(req.params).id;

export async function createDevice(req: Request, res: Response) {
  res.status(201).json(await service.createDevice(getCtx(req), DeviceCreateBody.parse(req.body)));
}
export async function updateDevice(req: Request, res: Response) {
  res.json(await service.updateDevice(getCtx(req), id(req), DeviceUpdateBody.parse(req.body)));
}
export async function setDeviceActive(req: Request, res: Response) {
  res.json(await service.setDeviceActive(getCtx(req), id(req), DeviceActiveBody.parse(req.body)));
}
export async function createPairingCode(req: Request, res: Response) {
  res.json(await service.createPairingCode(getCtx(req), id(req)));
}
export async function unpairDevice(req: Request, res: Response) {
  res.json(await service.unpairDevice(getCtx(req), id(req)));
}
export async function pairDevice(req: Request, res: Response) {
  res.json(await service.pairDevice(getCtx(req), DevicePairBody.parse(req.body).code));
}
/** The POS device this computer is paired with, as deviceContext resolved it. */
export async function currentDevice(req: Request, res: Response) {
  getCtx(req);
  res.json(CurrentDeviceResponse.parse({ device: req.device ?? null }));
}
