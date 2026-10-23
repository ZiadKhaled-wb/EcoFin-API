// server/src/offline/verify.ts
//
// S08 (D5, D10 step 1). What the worker checks before a received offline sale is posted or its
// receipt is sent:
//   - the signature: ECDSA P-256 over the UTF-8 bytes of the content exactly as stored, in the
//     IEEE P1363 form WebCrypto gives, with the public key the lease was issued to;
//   - the receipt UUID: the receipt serialized from its exact JSON text with header.uuid empty
//     (the shared serializer), hashed here with Node's crypto; it must equal both header.uuid and
//     the UUID stored when the sale was received.
// Neither function throws: anything unreadable is a failed check.

import { createPublicKey, verify } from 'node:crypto';
import {
  EtaDecimal,
  parseEtaJson,
  qrPayload,
  type EtaObject,
  type EtaValue,
} from '@ziadkhaled-wb/contracts';
import { receiptUuid, UUID_PATTERN } from '../eta/uuid';

export function verifyOfflineSignature(
  content: string,
  signatureBase64: string,
  publicKeyBase64: string,
): boolean {
  try {
    const key = createPublicKey({
      key: Buffer.from(publicKeyBase64, 'base64'),
      format: 'der',
      type: 'spki',
    });
    return verify(
      'sha256',
      Buffer.from(content, 'utf8'),
      { key, dsaEncoding: 'ieee-p1363' },
      Buffer.from(signatureBase64, 'base64'),
    );
  } catch {
    return false;
  }
}

const isObject = (value: EtaValue | undefined): value is EtaObject =>
  typeof value === 'object' &&
  value !== null &&
  !Array.isArray(value) &&
  !(value instanceof EtaDecimal);

const text = (value: EtaValue | undefined): string | null =>
  typeof value === 'string' ? value : value instanceof EtaDecimal ? value.text : null;

/** What the QR code of a receipt is made from, as the receipt carries it. */
export interface ReceiptFacts {
  uuid: string;
  dateTimeIssued: string;
  totalAmount: string;
  rin: string;
}

/**
 * The receipt's facts when its UUID is the hash of its own content and equals `storedUuid`;
 * null otherwise.
 */
export function checkReceiptUuid(
  receiptJson: string,
  storedUuid: string | null,
): ReceiptFacts | null {
  let receipt: EtaValue;
  try {
    receipt = parseEtaJson(receiptJson);
  } catch {
    return null;
  }
  if (!isObject(receipt)) return null;
  const header = receipt['header'];
  const seller = receipt['seller'];
  if (!isObject(header) || !isObject(seller)) return null;
  const uuid = text(header['uuid']);
  const dateTimeIssued = text(header['dateTimeIssued']);
  const totalAmount = text(receipt['totalAmount']);
  const rin = text(seller['rin']);
  if (uuid === null || !UUID_PATTERN.test(uuid) || uuid !== storedUuid) return null;
  if (dateTimeIssued === null || totalAmount === null || rin === null) return null;
  const computed = receiptUuid({ ...receipt, header: { ...header, uuid } });
  return computed === uuid ? { uuid, dateTimeIssued, totalAmount, rin } : null;
}

/** The QR text of a receipt (T02's builder), from the facts the receipt carries. */
export function offlineQr(portalUrl: string, facts: ReceiptFacts): string {
  return qrPayload({ portalUrl, ...facts });
}
