// server/src/middleware/deviceContext.ts
//
// O03 (D68): which POS device a request comes from.
//
//   deviceContext        after `authenticate`: reads the `x-device-token` header of a paired
//                        computer, hashes it and asks the database (public.resolve_device, as the
//                        caller: same shop, device active, branch active). Only then is
//                        req.device set, and only req.device becomes the `x-device-id` the
//                        database sees (requestMeta), sent with the token's hash as its proof
//                        (`x-device-token-hash`): the database is reachable without the API, so
//                        it counts a device id only with the hash it stores for that device.
//                        A device id or hash sent by the client is deleted.
//   resolveDevice        the same step for requestContext, which runs it on every route of a
//                        shop right after the session gate.
//
// No token: the request goes on without a device. A token that resolves to nothing (unpaired,
// deactivated, another shop's, its branch closed): 403 DEVICE_REVOKED, and the web app forgets
// the token. The token itself is never logged or stored; the database gets its hash.

import type { Request, Response, NextFunction } from 'express';
import { DEVICE_TOKEN_HEADER, type CurrentDevice } from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import { dbFor } from './auth';
import { asyncHandler } from '../utils/asyncHandler';
import { AppError, ServerError, mapDbError, safeMessage } from '../utils/errors';
import { isDeviceToken, sha256Hex } from '../utils/deviceSecrets';
import { logger } from '../utils/logger';
import type { DbClient } from '../utils/supabase';

/**
 * The paired POS device of one request. `tokenHash` is the SHA-256 of the token that resolved to
 * it: it goes to the database with the device id as the proof that the API resolved it, and
 * nowhere else (never into an answer or a log).
 */
export type RequestDevice = CurrentDevice & { tokenHash: string };

const Resolved = z.object({
  device_id: z.string().uuid(),
  name: z.string(),
  branch_id: z.string().uuid(),
  branch_name: z.string(),
});

function revoked(): AppError {
  return new AppError(safeMessage('DEVICE_REVOKED'), 'DEVICE_REVOKED');
}

/**
 * Sets req.device from the device token, or leaves it unset when there is none. `db` is a client
 * of the caller that carries no device id (the lookup must not depend on what it resolves).
 */
export async function resolveDevice(req: Request, db: DbClient = dbFor(req)): Promise<void> {
  delete req.headers['x-device-id'];
  delete req.headers['x-device-token-hash'];
  req.device = undefined;
  const token = req.headers[DEVICE_TOKEN_HEADER];
  if (token === undefined || token === '') return;
  if (!isDeviceToken(token)) throw revoked();

  const tokenHash = sha256Hex(token);
  const { data, error } = await db.rpc('resolve_device', { p_token_hash: tokenHash });
  if (error) {
    const mapped = mapDbError(error);
    if (mapped) throw mapped;
    logger.error({ err: error }, 'deviceContext: resolve_device failed');
    throw ServerError('Request failed.');
  }
  const device = Resolved.safeParse(data);
  if (!device.success) throw revoked();
  req.device = {
    id: device.data.device_id,
    name: device.data.name,
    branch_id: device.data.branch_id,
    branch_name: device.data.branch_name,
    tokenHash,
  };
}

export const deviceContext = asyncHandler(
  async (req: Request, _res: Response, next: NextFunction) => {
    if (!req.auth) throw new Error('deviceContext used before authenticate.');
    await resolveDevice(req);
    next();
  },
);
