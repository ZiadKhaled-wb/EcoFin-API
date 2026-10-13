import { z } from 'zod';
import { IsoTimestamp, Uuid } from './common.js';

/**
 * O03 POS devices (D69). A device is a row an owner creates; a computer becomes that device by
 * typing a one-time pairing code, and from then on sends its device token in a header. The code
 * and the token are each answered once and never again: only their hashes are stored.
 */

/** The request header that carries the device token of a paired computer. */
export const DEVICE_TOKEN_HEADER = 'x-device-token';

/** No 0/O, 1/I/L: the code is read from one screen and typed on another. */
export const PAIRING_CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
export const PAIRING_CODE_LENGTH = 8;
export const PAIRING_CODE_TTL_MINUTES = 15;
export const DEVICE_NAME_MAX = 50;

const deviceName = z.string().trim().min(1).max(DEVICE_NAME_MAX);

// POST /api/devices
export const DeviceCreateBody = z.object({ branch_id: Uuid, name: deviceName }).strict();
export type DeviceCreateBody = z.infer<typeof DeviceCreateBody>;
export const DeviceCreated = z.object({ id: Uuid });
export type DeviceCreated = z.infer<typeof DeviceCreated>;

// PATCH /api/devices/:id
export const DeviceUpdateBody = z
  .object({ name: deviceName.optional(), branch_id: Uuid.optional() })
  .strict()
  .refine((b) => b.name !== undefined || b.branch_id !== undefined, {
    message: 'Nothing to change',
  });
export type DeviceUpdateBody = z.infer<typeof DeviceUpdateBody>;

// POST /api/devices/:id/active
export const DeviceActiveBody = z
  .object({ active: z.boolean(), reason: z.string().trim().max(200).optional() })
  .strict()
  .refine((b) => b.active || (b.reason ?? '').length >= 1, {
    message: 'Turning a device off needs a reason',
    path: ['reason'],
  });
export type DeviceActiveBody = z.infer<typeof DeviceActiveBody>;
export const DeviceActiveResult = z.object({ id: Uuid, is_active: z.boolean() });
export type DeviceActiveResult = z.infer<typeof DeviceActiveResult>;

// POST /api/devices/:id/pairing-code
export const DevicePairingCode = z.object({ code: z.string(), expires_at: IsoTimestamp });
export type DevicePairingCode = z.infer<typeof DevicePairingCode>;

// POST /api/devices/:id/unpair
export const DeviceUnpaired = z.object({ id: Uuid, paired: z.literal(false) });
export type DeviceUnpaired = z.infer<typeof DeviceUnpaired>;

/** The POS device of this request: what a paired computer is told about itself. */
export const CurrentDevice = z.object({
  id: Uuid,
  name: z.string(),
  branch_id: Uuid,
  branch_name: z.string(),
});
export type CurrentDevice = z.infer<typeof CurrentDevice>;

// POST /api/devices/pair. Spaces, dashes and lower case are forgiven; a wrong shape is refused
// by the API as PAIRING_CODE_INVALID like any other wrong code.
export const DevicePairBody = z.object({ code: z.string().min(1).max(40) }).strict();
export type DevicePairBody = z.infer<typeof DevicePairBody>;
export const DevicePaired = z.object({ device_token: z.string(), device: CurrentDevice });
export type DevicePaired = z.infer<typeof DevicePaired>;

// GET /api/devices/current
export const CurrentDeviceResponse = z.object({ device: CurrentDevice.nullable() });
export type CurrentDeviceResponse = z.infer<typeof CurrentDeviceResponse>;

/** A typed code as the API compares it: upper case, without spaces or dashes. */
export function normalizePairingCode(input: string): string {
  return input.replace(/[\s-]/g, '').toUpperCase();
}

/** True when `code` has the shape of a pairing code (after normalizePairingCode). */
export function isPairingCode(code: string): boolean {
  return (
    code.length === PAIRING_CODE_LENGTH && [...code].every((c) => PAIRING_CODE_ALPHABET.includes(c))
  );
}
