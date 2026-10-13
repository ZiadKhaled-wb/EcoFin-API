// O03 POS devices (D69). Managing devices and pairing a computer with one. Everything goes through
// the caller's own client and the O03 database functions, which check the permission, the shop,
// the plan limit and write the audit row. The API makes the pairing code and the device token and
// hands the database their hashes only: each is answered once and then gone.
import {
  Device,
  DeviceActiveResult,
  DeviceCreated,
  DevicePaired,
  DevicePairingCode,
  DeviceUnpaired,
  isPairingCode,
  normalizePairingCode,
  type DeviceActiveBody,
  type DeviceCreateBody,
  type DeviceUpdateBody,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { RequestContext } from '../middleware/requestContext';
import { newDeviceToken, newPairingCode, pairingExpiry, sha256Hex } from '../utils/deviceSecrets';
import { AppError, mapDbError, safeMessage, ServerError } from '../utils/errors';

function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}

const PairedRow = z.object({
  device_id: z.string().uuid(),
  name: z.string(),
  branch_id: z.string().uuid(),
  branch_name: z.string(),
});

export async function createDevice(
  ctx: RequestContext,
  body: DeviceCreateBody,
): Promise<DeviceCreated> {
  const { data, error } = await ctx.db.rpc('create_device', {
    p_branch_id: body.branch_id,
    p_name: body.name,
  });
  if (error) fail(error);
  return DeviceCreated.parse({ id: data });
}

/** Rename, move to another branch, or both. A part left out stays as it is. */
export async function updateDevice(
  ctx: RequestContext,
  id: string,
  body: DeviceUpdateBody,
): Promise<Device> {
  const { data, error } = await ctx.db.rpc('update_device', {
    p_device_id: id,
    ...(body.name !== undefined ? { p_name: body.name } : {}),
    ...(body.branch_id !== undefined ? { p_branch_id: body.branch_id } : {}),
  });
  if (error) fail(error);
  return Device.parse(data);
}

export async function setDeviceActive(
  ctx: RequestContext,
  id: string,
  body: DeviceActiveBody,
): Promise<DeviceActiveResult> {
  const { data, error } = await ctx.db.rpc('set_device_active', {
    p_device_id: id,
    p_active: body.active,
    ...(body.reason !== undefined ? { p_reason: body.reason } : {}),
  });
  if (error) fail(error);
  return DeviceActiveResult.parse(data);
}

/** A new code for the device (an unused older one stops working). Answered here and never again. */
export async function createPairingCode(
  ctx: RequestContext,
  id: string,
): Promise<DevicePairingCode> {
  const code = newPairingCode();
  const expiresAt = pairingExpiry().toISOString();
  const { error } = await ctx.db.rpc('create_device_pairing_code', {
    p_device_id: id,
    p_code_hash: sha256Hex(code),
    p_expires_at: expiresAt,
  });
  if (error) fail(error);
  return DevicePairingCode.parse({ code, expires_at: expiresAt });
}

export async function unpairDevice(ctx: RequestContext, id: string): Promise<DeviceUnpaired> {
  const { data, error } = await ctx.db.rpc('unpair_device', { p_device_id: id });
  if (error) fail(error);
  return DeviceUnpaired.parse(data);
}

/**
 * Turns a typed code into a paired device: this computer gets a new device token (the device's
 * older token, if any, stops working). A code of the wrong shape never reaches the database and
 * fails the same way as a wrong one.
 */
export async function pairDevice(ctx: RequestContext, typed: string): Promise<DevicePaired> {
  const code = normalizePairingCode(typed);
  if (!isPairingCode(code)) {
    throw new AppError(safeMessage('PAIRING_CODE_INVALID'), 'PAIRING_CODE_INVALID');
  }
  const token = newDeviceToken();
  const { data, error } = await ctx.db.rpc('pair_device', {
    p_code_hash: sha256Hex(code),
    p_token_hash: sha256Hex(token),
  });
  if (error) fail(error);
  // NULL is the database's answer to every failed attempt (it counts them: 5 a minute for each
  // employee, also for calls that never came through this API).
  if (data === null) {
    throw new AppError(safeMessage('PAIRING_CODE_INVALID'), 'PAIRING_CODE_INVALID');
  }
  const row = PairedRow.parse(data);
  return DevicePaired.parse({
    device_token: token,
    device: {
      id: row.device_id,
      name: row.name,
      branch_id: row.branch_id,
      branch_name: row.branch_name,
    },
  });
}
