import { z } from 'zod';
import { IsoTimestamp, Uuid } from './common.js';
import { EtaEnvironment } from './eta.js';
import { computeDocumentTax } from './tax.js';
import { Percent } from './settings.js';
import { cleanText } from './eta/serialize.js';
import { buildReceiptBody, type Receipt, type ReceiptSource } from './eta/receipt.js';

/**
 * S08 offline cash sales (EC-75). When the internet drops, the POS keeps selling for cash under a
 * lease the server issued (limits, a price and stock snapshot, the device's ETA chain head). Each
 * offline sale is one JSON text (`content`, protocol v1) that the device signs and prints before
 * it is sent; the server stores it exactly as sent, checks it again and posts it once.
 *
 * Money is always a decimal string. The device and the server compute totals with the same T01
 * engine (computeOfflineTotals) and build the ETA receipt with the same builder (./eta).
 */

/** Content versions this build of the server accepts. A newer one waits on the device (retry_later). */
export const OFFLINE_SUPPORTED_VERSIONS = [1] as const;
export type OfflineVersion = (typeof OFFLINE_SUPPORTED_VERSIONS)[number];

/** D4: per-shop limits, with the bounds the database checks. */
export const OFFLINE_LIMIT_BOUNDS = {
  /** > 0 and < 150 000: from 150 000 EGP the ETA needs the buyer's national ID. */
  max_sale_total: { min: '0.01', maxExclusive: '150000.00', default: '20000.00' },
  /** 1 to 20 hours: leaves at least 4 hours before the ETA's 24-hour deadline. */
  max_hours: { min: 1, max: 20, default: 12 },
  max_sales: { min: 1, max: 1000, default: 100 },
  max_lease_total: { min: '0.01', default: '200000.00' },
} as const;

/** D14: a sale still on the device this long after it was made turns the banner red. */
export const OFFLINE_WARN_AFTER_HOURS = 18;
/** D1: an online sale that has no answer after this long becomes an offline sale (same key). */
export const OFFLINE_SALE_TIMEOUT_MS = 8000;
/** D1: the health check while offline, and how many good answers in a row bring the POS back. */
export const OFFLINE_HEALTH_EVERY_MS = 15000;
export const OFFLINE_HEALTH_OK_TO_RETURN = 2;
/** D2: the lease is renewed this often while online. */
export const OFFLINE_LEASE_REFRESH_MS = 15 * 60 * 1000;
/** D9 / D13: items per sync request, and per import. */
export const OFFLINE_SYNC_MAX_ITEMS = 50;
export const OFFLINE_IMPORT_MAX_ITEMS = 500;
/** D14: the PIN. */
export const OFFLINE_PIN = {
  pattern: /^\d{4,6}$/,
  iterations: 150000,
  maxTries: 5,
  idleLockMs: 5 * 60 * 1000,
} as const;

const NonNegativeMoney = z
  .string()
  .regex(/^\d{1,16}(\.\d{1,2})?$/, 'Money must be a non-negative decimal string');
const PositiveMoney = NonNegativeMoney.refine((v) => !/^0+(\.0+)?$/.test(v), 'Must be above 0');
/** UTC with whole seconds, as the ETA's dateTimeIssued: 2026-10-23T09:15:02Z. */
export const OfflineIssuedAt = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'UTC with whole seconds');
/** `OFF-` + the device's offline code + `-` + its sequence, at least 6 digits. */
export const OFFLINE_NUMBER_PATTERN = /^OFF-D[1-9]\d{0,5}-\d{6,}$/;

/** The sale number of an offline sale: OFF-D2-000123. */
export function offlineSaleNumber(offlineCode: string, seq: number): string {
  if (!/^D[1-9]\d{0,5}$/.test(offlineCode) || !Number.isInteger(seq) || seq < 1) {
    throw new RangeError('Not an offline code or sequence');
  }
  return `OFF-${offlineCode}-${String(seq).padStart(6, '0')}`;
}

// ---------------------------------------------------------------------------------------------
// The content (D6)

export const OfflineContentLine = z
  .object({
    product_id: Uuid,
    unit_id: Uuid.nullable(),
    quantity: z.number().int().min(1).max(100000),
    unit_price: NonNegativeMoney,
    tax_rate: Percent,
    tax_amount: NonNegativeMoney,
    line_total: NonNegativeMoney,
  })
  .strict()
  .refine((l) => l.unit_id === null || l.quantity === 1, 'A serialized line has quantity 1');
export type OfflineContentLine = z.infer<typeof OfflineContentLine>;

export const OfflineContentPayment = z
  .object({
    method: z.literal('cash'),
    amount: PositiveMoney,
    tendered: NonNegativeMoney,
    change: NonNegativeMoney,
  })
  .strict();
export type OfflineContentPayment = z.infer<typeof OfflineContentPayment>;

/**
 * The receipt inside the content: an ETA Receipt v1.2 with its UUID. Its fields are checked
 * against the body by the server (D9 step 6); here only its frame.
 */
export const OfflineContentReceipt = z
  .object({
    header: z
      .object({
        dateTimeIssued: z.string(),
        receiptNumber: z.string(),
        uuid: z.string().regex(/^[0-9a-f]{64}$/),
        previousUUID: z.string().regex(/^([0-9a-f]{64})?$/),
      })
      .passthrough(),
    seller: z
      .object({ rin: z.string(), branchCode: z.string(), deviceSerialNumber: z.string() })
      .passthrough(),
    itemData: z.array(z.object({ internalCode: z.string() }).passthrough()).min(1),
  })
  .passthrough();

/** One offline sale, protocol v1 (D6). JSON.parse of the content gives this shape. */
export const OfflineContent = z
  .object({
    v: z
      .number()
      .int()
      .refine(
        (v) => (OFFLINE_SUPPORTED_VERSIONS as readonly number[]).includes(v),
        'Unsupported content version',
      ),
    lease_id: Uuid,
    device_id: Uuid,
    seq: z.number().int().min(1),
    number: z.string().regex(OFFLINE_NUMBER_PATTERN),
    idempotency_key: Uuid,
    issued_at: OfflineIssuedAt,
    cashier_id: Uuid,
    lines: z.array(OfflineContentLine).min(1).max(100),
    subtotal: NonNegativeMoney,
    tax_total: NonNegativeMoney,
    total: PositiveMoney,
    payments: z.array(OfflineContentPayment).length(1),
    receipt: OfflineContentReceipt.nullable(),
  })
  .strict();
export type OfflineContent = z.infer<typeof OfflineContent>;

/** What the device writes into the content, before the receipt. */
export type OfflineContentFields = Omit<OfflineContent, 'v' | 'receipt'>;

/**
 * The content text exactly as it is signed, stored and sent: the D6 key order, compact, and the
 * receipt as its own JSON text (toJson of the receipt), so the receipt bytes the server takes out
 * of the content are the bytes the UUID was computed from.
 */
export function writeOfflineContent(
  fields: OfflineContentFields,
  receiptJson: string | null,
): string {
  const s = (value: string) => JSON.stringify(value);
  const line = (l: OfflineContentLine) =>
    `{"product_id":${s(l.product_id)},"unit_id":${l.unit_id === null ? 'null' : s(l.unit_id)},` +
    `"quantity":${l.quantity},"unit_price":${s(l.unit_price)},"tax_rate":${s(l.tax_rate)},` +
    `"tax_amount":${s(l.tax_amount)},"line_total":${s(l.line_total)}}`;
  const payment = (p: OfflineContentPayment) =>
    `{"method":"cash","amount":${s(p.amount)},"tendered":${s(p.tendered)},"change":${s(p.change)}}`;
  return (
    `{"v":1,"lease_id":${s(fields.lease_id)},"device_id":${s(fields.device_id)},` +
    `"seq":${fields.seq},"number":${s(fields.number)},` +
    `"idempotency_key":${s(fields.idempotency_key)},"issued_at":${s(fields.issued_at)},` +
    `"cashier_id":${s(fields.cashier_id)},"lines":[${fields.lines.map(line).join(',')}],` +
    `"subtotal":${s(fields.subtotal)},"tax_total":${s(fields.tax_total)},` +
    `"total":${s(fields.total)},"payments":[${fields.payments.map(payment).join(',')}],` +
    `"receipt":${receiptJson ?? 'null'}}`
  );
}

/** Reads a content text: the parsed sale, or null when it is not a v1 content. */
export function readOfflineContent(content: string): OfflineContent | null {
  try {
    const parsed = OfflineContent.safeParse(JSON.parse(content));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------------------------
// Totals (D7): T01, the same engine the server's sale core uses, with no discount.

export interface OfflineTotalsLine {
  unit_price: string;
  quantity: number;
  tax_rate: string;
}

export interface OfflineTotals {
  lines: { tax_amount: string; line_total: string }[];
  subtotal: string;
  tax_total: string;
  total: string;
}

/**
 * Each line's tax and total and the sale's subtotal, tax and total, exactly as T01's
 * app.compute_document_tax gives them for the same lines (no discount: offline sales have none).
 */
export function computeOfflineTotals(
  lines: readonly OfflineTotalsLine[],
  pricesIncludeVat: boolean,
): OfflineTotals {
  const tax = computeDocumentTax({
    prices_include_vat: pricesIncludeVat,
    document_discount: '0.00',
    lines: lines.map((l) => ({
      unit_price: l.unit_price,
      quantity: l.quantity,
      line_discount: '0.00',
      tax_rate: l.tax_rate,
    })),
  });
  return {
    lines: tax.lines.map((l) => ({ tax_amount: l.tax, line_total: l.gross })),
    subtotal: tax.subtotal,
    tax_total: tax.tax_total,
    total: tax.total,
  };
}

// ---------------------------------------------------------------------------------------------
// The snapshot (D3) and the lease (D2)

export const OFFLINE_NOT_SELLABLE_REASONS = ['NO_ETA_CODE', 'NO_PRICE'] as const;
export const OfflineNotSellableReason = z.enum(OFFLINE_NOT_SELLABLE_REASONS);
export type OfflineNotSellableReason = z.infer<typeof OfflineNotSellableReason>;

export const OfflineSnapshotProduct = z.object({
  id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  barcodes: z.array(z.string()),
  /** The walk-in price S01 would charge now; null = no price. */
  price: NonNegativeMoney.nullable(),
  tax_class_id: Uuid,
  tax_rate: Percent,
  eta_tax_type: z.string(),
  eta_subtype: z.string(),
  eta_item_code: z.string().nullable(),
  eta_item_type: z.string().nullable(),
  unit_type: z.string(),
  is_serialized: z.boolean(),
  /** Sellable stock of a non-serialized product; null for a serialized one. */
  on_hand: z.number().int().nullable(),
  /** The in-stock units of a serialized product. */
  units: z.array(z.object({ unit_id: Uuid, serial: z.string() })),
  offline_sellable: z.boolean(),
  reason: OfflineNotSellableReason.nullable(),
});
export type OfflineSnapshotProduct = z.infer<typeof OfflineSnapshotProduct>;

/** Never any cost, supplier or margin figure. */
export const OfflineSnapshotData = z.object({
  branch_id: Uuid,
  prices_include_vat: z.boolean(),
  eta_enabled: z.boolean(),
  products: z.array(OfflineSnapshotProduct),
});
export type OfflineSnapshotData = z.infer<typeof OfflineSnapshotData>;

export const OfflineLimits = z.object({
  max_sale_total: z.string(),
  max_hours: z.number().int(),
  max_sales: z.number().int(),
  max_lease_total: z.string(),
});
export type OfflineLimits = z.infer<typeof OfflineLimits>;

/** What the receipt's seller block is built from (T02's ReceiptSource.seller). */
export const OfflineSeller = z.object({
  rin: z.string().nullable(),
  name: z.string().nullable(),
  activity_code: z.string().nullable(),
  branch_code: z.string().nullable(),
  governorate: z.string().nullable(),
  city: z.string().nullable(),
  street: z.string().nullable(),
  building_number: z.string().nullable(),
});
export type OfflineSeller = z.infer<typeof OfflineSeller>;

/** POST /api/offline/lease */
export const OfflineLeaseBody = z
  .object({
    /** The device's ECDSA P-256 public key, SPKI, base64. */
    public_key: z
      .string()
      .regex(/^[A-Za-z0-9+/]+={0,2}$/)
      .min(80)
      .max(400),
    /** The snapshot the device holds (its content_hash), or null. */
    snapshot_hash: z
      .string()
      .regex(/^[0-9a-f]{64}$/)
      .nullable(),
  })
  .strict();
export type OfflineLeaseBody = z.infer<typeof OfflineLeaseBody>;

export const OfflineLease = z.object({
  id: Uuid,
  device_id: Uuid,
  shift_id: Uuid,
  branch_id: Uuid,
  cashier_id: Uuid,
  issued_at: IsoTimestamp,
  expires_at: IsoTimestamp,
  limits: OfflineLimits,
  snapshot_id: Uuid,
  snapshot_hash: z.string(),
  /** The device's ETA chain head when the lease was issued; "" = no receipt yet. */
  chain_head: z.string(),
  next_seq: z.number().int().min(1),
  key_id: Uuid,
});
export type OfflineLease = z.infer<typeof OfflineLease>;

export const OfflineLeaseResponse = z.object({
  lease: OfflineLease,
  /** The device's code in sale numbers (D1, D2, …). */
  offline_code: z.string(),
  server_time: IsoTimestamp,
  /** The snapshot's data, only when the device's hash differs. */
  snapshot: OfflineSnapshotData.nullable(),
  eta: z.object({
    enabled: z.boolean(),
    environment: EtaEnvironment.nullable(),
    /** The invoicing portal of the shop's ETA environment (the QR link). */
    portal_url: z.string().nullable(),
    seller: OfflineSeller.nullable(),
    device_serial: z.string().nullable(),
  }),
});
export type OfflineLeaseResponse = z.infer<typeof OfflineLeaseResponse>;

// ---------------------------------------------------------------------------------------------
// Sync and import (D9, D13)

export const OfflineItem = z
  .object({
    content: z.string().min(2).max(200000),
    signature: z
      .string()
      .regex(/^[A-Za-z0-9+/]+={0,2}$/)
      .min(40)
      .max(200),
  })
  .strict();
export type OfflineItem = z.infer<typeof OfflineItem>;

/** POST /api/offline/sync */
export const OfflineSyncBody = z
  .object({ items: z.array(OfflineItem).min(1).max(OFFLINE_SYNC_MAX_ITEMS) })
  .strict();
export type OfflineSyncBody = z.infer<typeof OfflineSyncBody>;

/** POST /api/offline/import */
export const OfflineImportBody = z
  .object({ device_id: Uuid, items: z.array(OfflineItem).min(1).max(OFFLINE_IMPORT_MAX_ITEMS) })
  .strict();
export type OfflineImportBody = z.infer<typeof OfflineImportBody>;

export const OFFLINE_ITEM_RESULTS = ['received', 'duplicate', 'rejected', 'retry_later'] as const;
export const OfflineItemResult = z.enum(OFFLINE_ITEM_RESULTS);
export type OfflineItemResult = z.infer<typeof OfflineItemResult>;

export const OfflineItemOutcome = z.object({
  /** The item's position in the request. */
  index: z.number().int().min(0),
  seq: z.number().int().nullable(),
  result: OfflineItemResult,
  /** Why it was rejected or must wait (SEQ_REUSED, NOT_OURS, UNSUPPORTED_VERSION, INVALID_CONTENT). */
  code: z.string().nullable(),
});
export type OfflineItemOutcome = z.infer<typeof OfflineItemOutcome>;

export const OfflineSyncResponse = z.object({ results: z.array(OfflineItemOutcome) });
export type OfflineSyncResponse = z.infer<typeof OfflineSyncResponse>;

/** The device keeps an item only while it must wait; every other answer counts as synced. */
export const offlineItemDone = (result: OfflineItemResult): boolean => result !== 'retry_later';

// ---------------------------------------------------------------------------------------------
// Review (D10, D11)

export const OFFLINE_SALE_STATUSES = [
  'received',
  'posted',
  'conflict',
  'duplicate',
  'rejected',
] as const;
export const OfflineSaleStatus = z.enum(OFFLINE_SALE_STATUSES);
export type OfflineSaleStatus = z.infer<typeof OfflineSaleStatus>;

export const OFFLINE_CONFLICT_CODES = [
  'SHIFT_CLOSED',
  'TIME_INVALID',
  'LIMIT_EXCEEDED',
  'PRICE_MISMATCH',
  'TOTALS_MISMATCH',
  'SERIAL_UNAVAILABLE',
] as const;
export const OfflineConflictCode = z.enum(OFFLINE_CONFLICT_CODES);
export type OfflineConflictCode = z.infer<typeof OfflineConflictCode>;

export const OFFLINE_REJECT_CODES = ['VERIFY_FAILED', 'NOT_OURS', 'LEASE_REVOKED'] as const;
export const OFFLINE_FISCAL_HOLDS = ['RECEIPT_MISMATCH', 'LEASE_REVOKED'] as const;
export const OfflineFiscalHold = z.enum(OFFLINE_FISCAL_HOLDS);
export type OfflineFiscalHold = z.infer<typeof OfflineFiscalHold>;

export const OFFLINE_FLAGS = [
  'seq_gap',
  'stock_adjusted',
  'reprint_needed',
  'late_business_date',
] as const;

export const OFFLINE_ACTIONS = ['accept', 'use_serial', 'post_to_shift', 'reject'] as const;
export const OfflineAction = z.enum(OFFLINE_ACTIONS);
export type OfflineAction = z.infer<typeof OfflineAction>;

/**
 * D11: the actions a manager may take on a sale, from its conflict code and fiscal hold.
 * TOTALS_MISMATCH and RECEIPT_MISMATCH have none: they are bugs, raised by an alert.
 */
export function offlineActionsFor(sale: {
  status: OfflineSaleStatus;
  conflict_code: string | null;
  fiscal_hold: string | null;
}): OfflineAction[] {
  if (
    sale.fiscal_hold === 'LEASE_REVOKED' &&
    (sale.status === 'received' || sale.status === 'conflict')
  ) {
    return ['accept', 'reject'];
  }
  if (sale.status !== 'conflict') return [];
  switch (sale.conflict_code) {
    case 'TIME_INVALID':
    case 'LIMIT_EXCEEDED':
    case 'PRICE_MISMATCH':
      return ['accept'];
    case 'SERIAL_UNAVAILABLE':
      return ['use_serial'];
    case 'SHIFT_CLOSED':
      return ['post_to_shift'];
    default:
      return [];
  }
}

export const OfflineSaleListQuery = z
  .object({ status: OfflineSaleStatus.optional(), branch_id: Uuid.optional() })
  .strict();
export type OfflineSaleListQuery = z.infer<typeof OfflineSaleListQuery>;

export const OfflineSaleIdParams = z.object({ id: Uuid }).strict();

export const OfflineSaleSummary = z.object({
  id: Uuid,
  number: z.string(),
  seq: z.number().int(),
  device_id: Uuid,
  device_name: z.string().nullable(),
  branch_id: Uuid,
  branch_name: z.string().nullable(),
  shift_id: Uuid.nullable(),
  /** null for a sale whose lease is not the device's (it is refused as NOT_OURS). */
  cashier_id: Uuid.nullable(),
  cashier_name: z.string().nullable(),
  issued_at: IsoTimestamp,
  received_at: IsoTimestamp,
  total: z.string(),
  source: z.enum(['sync', 'import']),
  status: OfflineSaleStatus,
  conflict_code: z.string().nullable(),
  fiscal_hold: z.string().nullable(),
  flags: z.array(z.string()),
  sale_id: Uuid.nullable(),
  resolved_at: IsoTimestamp.nullable(),
  resolution_reason: z.string().nullable(),
});
export type OfflineSaleSummary = z.infer<typeof OfflineSaleSummary>;

export const OfflineSaleList = z.array(OfflineSaleSummary);
export type OfflineSaleList = z.infer<typeof OfflineSaleList>;

export const OfflineSaleDetailLine = z.object({
  line_no: z.number().int(),
  product_id: Uuid,
  name_ar: z.string().nullable(),
  name_en: z.string().nullable(),
  sku: z.string().nullable(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  quantity: z.number().int(),
  unit_price: z.string(),
  tax_rate: z.string(),
  tax_amount: z.string(),
  line_total: z.string(),
});
export type OfflineSaleDetailLine = z.infer<typeof OfflineSaleDetailLine>;

/** One offline sale as printed: never the content text, the receipt JSON or the signature. */
export const OfflineSaleDetail = OfflineSaleSummary.extend({
  lines: z.array(OfflineSaleDetailLine),
  subtotal: z.string(),
  tax_total: z.string(),
  payment: z.object({ amount: z.string(), tendered: z.string(), change: z.string() }),
  eta_uuid: z.string().nullable(),
  previous_uuid: z.string().nullable(),
  overrides: z.record(z.unknown()),
  actions: z.array(OfflineAction),
});
export type OfflineSaleDetail = z.infer<typeof OfflineSaleDetail>;

/** POST /api/offline/sales/:id/resolve */
export const OfflineResolveBody = z
  .object({
    action: OfflineAction,
    reason: z.string().trim().min(3).max(500),
    /** use_serial: { line number: unit id }. */
    unit_ids: z.record(z.string().regex(/^[1-9]\d{0,2}$/), Uuid).optional(),
    /** post_to_shift: an open shift of the same branch. */
    shift_id: Uuid.optional(),
  })
  .strict();
export type OfflineResolveBody = z.infer<typeof OfflineResolveBody>;

// ---------------------------------------------------------------------------------------------
// Settings (D16)

export const OfflineSettings = z.object({
  offline_enabled: z.boolean(),
  offline_max_sale_total: z.string(),
  offline_max_hours: z.number().int(),
  offline_max_sales: z.number().int(),
  offline_max_lease_total: z.string(),
});
export type OfflineSettings = z.infer<typeof OfflineSettings>;

export const OfflineSettingsBody = z
  .object({
    offline_enabled: z.boolean(),
    offline_max_sale_total: PositiveMoney.refine(
      (v) => Number(v) < 150000,
      'Below 150000 (the ETA needs the buyer ID from there)',
    ),
    offline_max_hours: z
      .number()
      .int()
      .min(OFFLINE_LIMIT_BOUNDS.max_hours.min)
      .max(OFFLINE_LIMIT_BOUNDS.max_hours.max),
    offline_max_sales: z
      .number()
      .int()
      .min(OFFLINE_LIMIT_BOUNDS.max_sales.min)
      .max(OFFLINE_LIMIT_BOUNDS.max_sales.max),
    offline_max_lease_total: PositiveMoney,
  })
  .strict();
export type OfflineSettingsBody = z.infer<typeof OfflineSettingsBody>;

/** GET /api/health: the POS's connectivity check (no auth, no database). */
export const ApiHealth = z.object({ ok: z.literal(true) });
export type ApiHealth = z.infer<typeof ApiHealth>;

// ---------------------------------------------------------------------------------------------
// The offline receipt (D6, D7): the device builds it with T02's builder.

export interface OfflineReceiptInput {
  number: string;
  issued_at: string;
  prices_include_vat: boolean;
  total: string;
  lines: readonly (OfflineContentLine & {
    product: Pick<
      OfflineSnapshotProduct,
      'sku' | 'name_ar' | 'eta_item_code' | 'eta_item_type' | 'eta_tax_type' | 'eta_subtype'
    >;
  })[];
  seller: OfflineSeller;
  device_serial: string | null;
}

/** The sale as T02's builder reads a stored sale: a walk-in customer, paid in cash. */
export function offlineReceiptSource(input: OfflineReceiptInput): ReceiptSource {
  return {
    sale: {
      number: input.number,
      issued_at: input.issued_at,
      prices_include_vat: input.prices_include_vat,
      total: input.total,
    },
    lines: input.lines.map((l, i) => ({
      line_no: i + 1,
      quantity: l.quantity,
      unit_price: l.unit_price,
      discount_amount: '0.00',
      tax_rate: l.tax_rate,
      tax_amount: l.tax_amount,
      line_total: l.line_total,
      sku: l.product.sku,
      name: l.product.name_ar,
      eta_item_code: l.product.eta_item_code,
      eta_item_type: l.product.eta_item_type,
      eta_tax_type: l.product.eta_tax_type,
      eta_subtype: l.product.eta_subtype,
    })),
    payments: [{ method: 'cash', amount: input.total }],
    customer: null,
    seller: input.seller,
    device: { serial: input.device_serial, status: 'active', is_active: true },
  };
}

/** The offline sale's receipt with header.uuid empty; the device hashes and fills it. */
export function buildOfflineReceiptBody(input: OfflineReceiptInput, previousUuid: string): Receipt {
  return buildReceiptBody(offlineReceiptSource(input), previousUuid);
}

/** The SKU as the receipt writes it (the server compares internalCode with it). */
export const offlineInternalCode = (sku: string): string => cleanText(sku, 50);
