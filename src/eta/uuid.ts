// server/src/eta/uuid.ts
//
// T02 (D67). A receipt's UUID (docs/eta/ERECEIPT_SPEC.md, section 9): the SHA-256 of the
// serialized receipt with header.uuid empty, as 64 lower-case hex characters. The receipt
// already carries its previousUUID (and a return its referenceUUID), so both are part of it.
// S08 (D7): the serialization lives in contracts (the POS hashes the same text with
// crypto.subtle); the hashing stays here, with Node's crypto.

import { createHash } from 'node:crypto';
import {
  receiptUuidInput,
  UUID_PATTERN,
  withReceiptUuid,
  type HasReceiptHeader,
} from '@ziadkhaled-wb/contracts';

export { UUID_PATTERN, type HasReceiptHeader };

/** The UUID of this receipt, whatever its header.uuid holds now. */
export function receiptUuid(receipt: HasReceiptHeader): string {
  return createHash('sha256').update(receiptUuidInput(receipt), 'utf8').digest('hex');
}

/** The same receipt with its UUID filled in (property order unchanged). */
export function withUuid<T extends HasReceiptHeader>(receipt: T): T {
  return withReceiptUuid(receipt, receiptUuid(receipt));
}
