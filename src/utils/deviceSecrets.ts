// O03 (D69): the two secrets of a POS device. The pairing code is shown once on the owner's
// screen and typed on the POS computer; the device token is answered once to that computer.
// Only their SHA-256 hashes go to the database, and neither is ever logged, returned again or
// written to the audit log.
import { createHash, randomBytes, randomInt } from 'node:crypto';
import {
  PAIRING_CODE_ALPHABET,
  PAIRING_CODE_LENGTH,
  PAIRING_CODE_TTL_MINUTES,
} from '@ziadkhaled-wb/contracts';

/** 32 random bytes as base64url: always 43 characters, no padding. */
const DEVICE_TOKEN = /^[A-Za-z0-9_-]{43}$/;

/** SHA-256 as 64 lower-case hex characters: the only form a code or token is stored in. */
export function sha256Hex(secret: string): string {
  return createHash('sha256').update(secret, 'utf8').digest('hex');
}

/** 8 characters, each drawn evenly from the 31 of the alphabet. */
export function newPairingCode(): string {
  let code = '';
  for (let i = 0; i < PAIRING_CODE_LENGTH; i += 1) {
    code += PAIRING_CODE_ALPHABET.charAt(randomInt(PAIRING_CODE_ALPHABET.length));
  }
  return code;
}

export function pairingExpiry(now: Date = new Date()): Date {
  return new Date(now.getTime() + PAIRING_CODE_TTL_MINUTES * 60 * 1000);
}

/** 32 random bytes, base64url. */
export function newDeviceToken(): string {
  return randomBytes(32).toString('base64url');
}

export function isDeviceToken(value: unknown): value is string {
  return typeof value === 'string' && DEVICE_TOKEN.test(value);
}
