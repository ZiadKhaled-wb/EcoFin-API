import pino from 'pino';
import { describe, expect, it } from 'vitest';
import {
  qrPayload,
  readOfflineContent,
  toJson,
  type OfflineLeaseResponse,
  type OfflineSnapshotData,
} from '@ziadkhaled-wb/contracts';
import { buildReceipt, type ReceiptSource } from '../eta/build-receipt';
import type { EtaHostMap } from '../eta/config';
import type { Job } from '../jobs/types';
import { buildOfflineSale, newDeviceKeys, publicKeyBase64, signContent } from '../test/offline';
import { offlineJobHandlers, verifyRow, type OfflineStore, type ReceivedRow } from './process';
import { checkReceiptUuid, verifyOfflineSignature } from './verify';

const TV = '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b01';
const CUP = '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b02';
const product = (id: string, sku: string, name: string, price: string) => ({
  id,
  name_ar: name,
  name_en: null,
  sku,
  barcodes: [],
  price,
  tax_class_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b20',
  tax_rate: '14.00',
  eta_tax_type: 'T1',
  eta_subtype: 'V009',
  eta_item_code: `EG-674859545-${sku}`,
  eta_item_type: 'EGS',
  unit_type: 'EA',
  is_serialized: false,
  on_hand: 10,
  units: [],
  offline_sellable: true,
  reason: null,
});
const snapshot: OfflineSnapshotData = {
  branch_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b10',
  prices_include_vat: true,
  eta_enabled: true,
  // A quote in a name: the receipt writes it as ' (T02's cleanText), on both sides.
  products: [
    product(TV, 'S8-TV', 'تلفزيون', '1140.00'),
    product(CUP, 'S8-CUP', 'كوب "صغير"', '33.33'),
  ],
};
const seller = {
  rin: '674859545',
  name: 'S08 Shop A LLC',
  activity_code: '4753',
  branch_code: '0',
  governorate: 'Cairo',
  city: 'Nasr City',
  street: '16 Abbas El Akkad',
  building_number: '14',
};
const lease: OfflineLeaseResponse = {
  lease: {
    id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b30',
    device_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b31',
    shift_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b32',
    branch_id: snapshot.branch_id,
    cashier_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b33',
    issued_at: '2026-10-23T09:00:00.000Z',
    expires_at: '2026-10-23T21:00:00.000Z',
    limits: {
      max_sale_total: '20000.00',
      max_hours: 12,
      max_sales: 100,
      max_lease_total: '200000.00',
    },
    snapshot_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b34',
    snapshot_hash: 'a'.repeat(64),
    chain_head: '',
    next_seq: 1,
    key_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b35',
  },
  offline_code: 'D2',
  server_time: '2026-10-23T09:00:00.000Z',
  snapshot,
  eta: {
    enabled: true,
    environment: 'preprod',
    portal_url: 'https://preprod.invoicing.eta.gov.eg',
    seller,
    device_serial: 'POS-A1',
  },
};
const hosts = {
  preprod: {
    idUrl: 'https://id.preprod',
    apiUrl: 'https://api.preprod',
    portalUrl: 'https://preprod.invoicing.eta.gov.eg',
  },
  prod: { idUrl: 'https://id', apiUrl: 'https://api', portalUrl: 'https://invoicing.eta.gov.eg' },
} satisfies EtaHostMap;
const PREVIOUS = 'b'.repeat(64);
const ISSUED = '2026-10-23T09:15:02Z';

const sale = () =>
  buildOfflineSale({
    lease,
    snapshot,
    seq: 7,
    previousUuid: PREVIOUS,
    issuedAt: ISSUED,
    lines: [
      { product_id: TV, quantity: 2 },
      { product_id: CUP, quantity: 3 },
    ],
  });

function receivedRow(content: string, signature: string, publicKey = 'AAAA'): ReceivedRow {
  return {
    id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b40',
    organization_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b41',
    device_id: lease.lease.device_id,
    seq: 7,
    number: 'OFF-D2-000007',
    content,
    signature,
    eta_uuid: null,
    public_key: publicKey,
    environment: 'preprod',
    receipt_json: null,
  };
}

describe('U3 the offline receipt is the server receipt of the same sale', () => {
  it('same text and the same UUID as T02 builds from the posted sale', () => {
    const built = sale();
    const content = readOfflineContent(built.content);
    expect(content).not.toBeNull();
    // The sale as T02's loader reads it once it is posted: the same lines, no discount, cash.
    const source: ReceiptSource = {
      sale: {
        number: built.number,
        issued_at: ISSUED,
        prices_include_vat: true,
        total: built.total,
      },
      lines: content!.lines.map((l, i) => {
        const p = snapshot.products.find((x) => x.id === l.product_id)!;
        return {
          line_no: i + 1,
          quantity: l.quantity,
          unit_price: l.unit_price,
          discount_amount: '0.00',
          tax_rate: l.tax_rate,
          tax_amount: l.tax_amount,
          line_total: l.line_total,
          sku: p.sku,
          name: p.name_ar,
          eta_item_code: p.eta_item_code,
          eta_item_type: p.eta_item_type,
          eta_tax_type: p.eta_tax_type,
          eta_subtype: p.eta_subtype,
        };
      }),
      payments: [{ method: 'cash', amount: built.total }],
      customer: null,
      seller,
      device: { serial: 'POS-A1', status: 'active', is_active: true },
    };
    const server = buildReceipt(source, PREVIOUS);
    expect(toJson(built.receipt!)).toBe(toJson(server));
    expect(built.uuid).toBe(server.header.uuid);
    expect(built.receipt!.header.receiptNumber).toBe('OFF-D2-000007');
    expect(content!.total).toBe(built.receipt!.totalAmount.text);
  });

  it('the content carries the receipt text exactly (the server takes those bytes)', () => {
    const built = sale();
    expect(built.content).toContain(`"receipt":${toJson(built.receipt!)}}`);
    expect(checkReceiptUuid(toJson(built.receipt!), built.uuid)).not.toBeNull();
  });
});

describe('U4 the QR text of an offline receipt', () => {
  it("is T02's format with the receipt's own date and total text", () => {
    const built = sale();
    const facts = checkReceiptUuid(toJson(built.receipt!), built.uuid)!;
    const row = {
      ...receivedRow(built.content, 'x'),
      receipt_json: toJson(built.receipt!),
      eta_uuid: built.uuid,
    };
    expect(verifyRow(row, hosts).qr).toBe(
      qrPayload({
        portalUrl: 'https://preprod.invoicing.eta.gov.eg',
        uuid: built.uuid!,
        dateTimeIssued: ISSUED,
        totalAmount: facts.totalAmount,
        rin: '674859545',
      }),
    );
    expect(verifyRow(row, hosts).qr).toBe(
      `https://preprod.invoicing.eta.gov.eg/receipts/search/${built.uuid}/share/${ISSUED}` +
        `#Total:${built.total},IssuerRIN:674859545`,
    );
  });

  it('a changed receipt fails the UUID check (and has no QR)', () => {
    const built = sale();
    const tampered = toJson(built.receipt!).replace('"totalAmount":', '"totalAmount":1');
    expect(checkReceiptUuid(tampered, built.uuid)).toBeNull();
    expect(checkReceiptUuid(toJson(built.receipt!), 'c'.repeat(64))).toBeNull();
    expect(checkReceiptUuid('not json', built.uuid)).toBeNull();
  });
});

describe('U5 a WebCrypto signature is verified by Node (P1363)', () => {
  it('verifies, and one changed byte of the content or the signature fails', async () => {
    const keys = await newDeviceKeys();
    const publicKey = await publicKeyBase64(keys);
    const { content } = sale();
    const signature = await signContent(keys, content);
    expect(Buffer.from(signature, 'base64')).toHaveLength(64);
    expect(verifyOfflineSignature(content, signature, publicKey)).toBe(true);
    const changed = content.replace('"quantity":2', '"quantity":3');
    expect(changed).not.toBe(content);
    expect(verifyOfflineSignature(changed, signature, publicKey)).toBe(false);
    const raw = Buffer.from(signature, 'base64');
    raw[10] = raw[10]! ^ 1;
    expect(verifyOfflineSignature(content, raw.toString('base64'), publicKey)).toBe(false);
    const other = await publicKeyBase64(await newDeviceKeys());
    expect(verifyOfflineSignature(content, signature, other)).toBe(false);
    expect(verifyOfflineSignature(content, signature, 'not a key')).toBe(false);
  });
});

describe('the offline.process job', () => {
  it('verifies each row in sequence order, passes the QR, stops when nothing is left', async () => {
    const keys = await newDeviceKeys();
    const publicKey = await publicKeyBase64(keys);
    const good = sale();
    const goodRow: ReceivedRow = {
      ...receivedRow(good.content, await signContent(keys, good.content), publicKey),
      receipt_json: toJson(good.receipt!),
      eta_uuid: good.uuid,
    };
    const raw = Buffer.from(goodRow.signature, 'base64');
    raw[0] = raw[0]! ^ 1;
    const badRow: ReceivedRow = {
      ...goodRow,
      id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2b42',
      seq: 8,
      signature: raw.toString('base64'),
    };
    const calls: { id: string; sig: boolean; uuid: boolean; qr: string | null }[] = [];
    let pending = [goodRow, badRow];
    const store: OfflineStore = {
      loadReceived: () => Promise.resolve(pending),
      process: (id, sig, uuid, qr) => {
        calls.push({ id, sig, uuid, qr });
        pending = pending.filter((r) => r.id !== id);
        return Promise.resolve({
          id,
          status: sig ? 'posted' : 'rejected',
          released: sig,
          alerts: sig ? [] : ['VERIFY_FAILED'],
        });
      },
    };
    const job: Job = {
      id: 'job',
      organizationId: goodRow.organization_id,
      type: 'offline.process',
      payload: { device_id: goodRow.device_id },
      attempt: 1,
      maxAttempts: 5,
    };
    await offlineJobHandlers({ store, hosts, batchSize: 2 })['offline.process'](
      job,
      pino({ level: 'silent' }),
    );
    expect(calls.map((c) => [c.id, c.sig, c.uuid])).toEqual([
      [goodRow.id, true, true],
      [badRow.id, false, true],
    ]);
    expect(calls[0]!.qr).toContain(`/receipts/search/${good.uuid}/share/`);
  });

  it('a row another run holds is skipped, and the job ends', async () => {
    let loads = 0;
    const store: OfflineStore = {
      loadReceived: () => {
        loads += 1;
        return Promise.resolve([receivedRow('{}', 'AAAA')]);
      },
      process: (id) => Promise.resolve({ id, skipped: true }),
    };
    const job: Job = {
      id: 'job',
      organizationId: null,
      type: 'offline.process',
      payload: { device_id: lease.lease.device_id },
      attempt: 1,
      maxAttempts: 5,
    };
    await offlineJobHandlers({ store, hosts, batchSize: 1 })['offline.process'](
      job,
      pino({ level: 'silent' }),
    );
    expect(loads).toBe(1);
  });
});
