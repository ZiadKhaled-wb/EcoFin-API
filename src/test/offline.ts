// src/test/offline.ts
//
// S08 test helper: an offline sale built and signed the way the POS builds it (EcoFin-Web
// src/offline/saleBuilder.ts): the contracts' totals, receipt builder, serializer and content
// writer; a WebCrypto ECDSA P-256 key (non-extractable private key) and an IEEE P1363 signature.
// Only the hashing differs from the browser: Node's crypto here, crypto.subtle there.

import { createHash, webcrypto } from 'node:crypto';
import {
  buildOfflineReceiptBody,
  computeOfflineTotals,
  offlineSaleNumber,
  receiptUuidInput,
  toJson,
  withReceiptUuid,
  writeOfflineContent,
  type OfflineContentFields,
  type OfflineContentLine,
  type OfflineLeaseResponse,
  type OfflineSnapshotData,
  type Receipt,
} from '@ziadkhaled-wb/contracts';

export type DeviceKeys = webcrypto.CryptoKeyPair;

export async function newDeviceKeys(): Promise<DeviceKeys> {
  return webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, [
    'sign',
    'verify',
  ]);
}

export async function publicKeyBase64(keys: DeviceKeys): Promise<string> {
  const spki = await webcrypto.subtle.exportKey('spki', keys.publicKey);
  return Buffer.from(spki).toString('base64');
}

/** The content's signature as the POS makes it: ECDSA SHA-256, P1363, base64. */
export async function signContent(keys: DeviceKeys, content: string): Promise<string> {
  const signature = await webcrypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    keys.privateKey,
    new TextEncoder().encode(content),
  );
  return Buffer.from(signature).toString('base64');
}

export interface OfflineSaleInput {
  lease: OfflineLeaseResponse;
  snapshot: OfflineSnapshotData;
  seq: number;
  /** previousUUID of the receipt ("" for the device's first). */
  previousUuid: string;
  lines: { product_id: string; quantity: number; unit_id?: string | null; unit_price?: string }[];
  /** UTC with whole seconds; default: now. */
  issuedAt?: string;
  idempotencyKey?: string;
}

export interface OfflineSaleBuilt {
  content: string;
  number: string;
  receipt: Receipt | null;
  uuid: string | null;
  total: string;
  idempotencyKey: string;
}

export const isoSeconds = (date: Date): string => date.toISOString().replace(/\.\d{3}Z$/, 'Z');

export function buildOfflineSale(input: OfflineSaleInput): OfflineSaleBuilt {
  const { lease, snapshot } = input;
  const products = input.lines.map((line) => {
    const product = snapshot.products.find((p) => p.id === line.product_id);
    if (!product) throw new Error('The product is not in the snapshot');
    return product;
  });
  const priced = input.lines.map((line, i) => ({
    unit_price: line.unit_price ?? products[i]!.price ?? '0.00',
    quantity: line.quantity,
    tax_rate: products[i]!.tax_rate,
  }));
  const totals = computeOfflineTotals(priced, snapshot.prices_include_vat);
  const lines: OfflineContentLine[] = input.lines.map((line, i) => ({
    product_id: line.product_id,
    unit_id: line.unit_id ?? null,
    quantity: line.quantity,
    unit_price: priced[i]!.unit_price,
    tax_rate: priced[i]!.tax_rate,
    tax_amount: totals.lines[i]!.tax_amount,
    line_total: totals.lines[i]!.line_total,
  }));
  const number = offlineSaleNumber(lease.offline_code, input.seq);
  const issuedAt = input.issuedAt ?? isoSeconds(new Date());
  const idempotencyKey = input.idempotencyKey ?? webcrypto.randomUUID();

  let receipt: Receipt | null = null;
  if (lease.eta.enabled && lease.eta.seller) {
    const body = buildOfflineReceiptBody(
      {
        number,
        issued_at: issuedAt,
        prices_include_vat: snapshot.prices_include_vat,
        total: totals.total,
        lines: lines.map((line, i) => ({ ...line, product: products[i]! })),
        seller: lease.eta.seller,
        device_serial: lease.eta.device_serial,
      },
      input.previousUuid,
    );
    const uuid = createHash('sha256').update(receiptUuidInput(body), 'utf8').digest('hex');
    receipt = withReceiptUuid(body, uuid);
  }

  const fields: OfflineContentFields = {
    lease_id: lease.lease.id,
    device_id: lease.lease.device_id,
    seq: input.seq,
    number,
    idempotency_key: idempotencyKey,
    issued_at: issuedAt,
    cashier_id: lease.lease.cashier_id,
    lines,
    subtotal: totals.subtotal,
    tax_total: totals.tax_total,
    total: totals.total,
    payments: [{ method: 'cash', amount: totals.total, tendered: totals.total, change: '0.00' }],
  };
  return {
    content: writeOfflineContent(fields, receipt ? toJson(receipt) : null),
    number,
    receipt,
    uuid: receipt?.header.uuid ?? null,
    total: totals.total,
    idempotencyKey,
  };
}
