// server/src/eta/uuid.ts
//
// T02 (D67). A receipt's UUID (docs/eta/ERECEIPT_SPEC.md, section 9): the SHA-256 of the
// serialized receipt with header.uuid empty, as 64 lower-case hex characters. The receipt
// already carries its previousUUID (and a return its referenceUUID), so both are part of it.

import { createHash } from 'node:crypto';
import { serialize, type EtaObject } from './serialize';

/** Any receipt: only the header's uuid matters here. */
export interface HasReceiptHeader extends EtaObject {
  readonly header: EtaObject & { readonly uuid: string };
}

export const UUID_PATTERN = /^[0-9a-f]{64}$/;

/** The UUID of this receipt, whatever its header.uuid holds now. */
export function receiptUuid(receipt: HasReceiptHeader): string {
  const blank = { ...receipt, header: { ...receipt.header, uuid: '' } };
  return createHash('sha256').update(serialize(blank), 'utf8').digest('hex');
}

/** The same receipt with its UUID filled in (property order unchanged). */
export function withUuid<T extends HasReceiptHeader>(receipt: T): T {
  return { ...receipt, header: { ...receipt.header, uuid: receiptUuid(receipt) } };
}
