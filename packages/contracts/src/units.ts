import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';
import { UnitStatus } from './products.js';
import { AdjustmentReason, StockMovementType } from './stock.js';

/**
 * I04 serial / IMEI units (D50). A serial is stored trimmed and upper-cased (the same IMEI typed
 * in lower case is the same unit): 1-64 characters of A-Z, 0-9 and . _ / -.
 */
export const SERIAL_PATTERN = /^[A-Z0-9][A-Z0-9._/-]{0,63}$/;
export const Serial = z
  .string()
  .transform((v) => v.trim().toUpperCase())
  .pipe(z.string().regex(SERIAL_PATTERN, 'Not a serial'));
export type Serial = z.infer<typeof Serial>;

/**
 * `POST /api/units` (stock.adjust, serials module, `Idempotency-Key`): registers serials the shop
 * already holds as opening stock (until purchases, U02, create them on receipt).
 */
export const UnitRegisterBody = z
  .object({
    product_id: Uuid,
    branch_id: Uuid,
    cost: Money.refine((v) => !v.startsWith('-'), 'Must not be negative'),
    serials: z.array(Serial).min(1).max(500),
    note: z
      .string()
      .trim()
      .max(500)
      .nullish()
      .transform((v) => (v ? v : undefined)),
  })
  .strict()
  .superRefine((b, ctx) => {
    const seen = new Set<string>();
    b.serials.forEach((s, i) => {
      if (seen.has(s)) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['serials', i], message: 'Repeated' });
      }
      seen.add(s);
    });
  });
export type UnitRegisterBody = z.infer<typeof UnitRegisterBody>;

export const UnitRegistration = z.object({
  import_job_id: Uuid,
  product_id: Uuid,
  branch_id: Uuid,
  cost: Money,
  note: z.string().nullable(),
  count: z.number().int().positive(),
  units: z.array(z.object({ id: Uuid, serial: z.string() })),
});
export type UnitRegistration = z.infer<typeof UnitRegistration>;

/** Detail of SERIAL_TAKEN: the serials that are repeated or already in the shop. */
export const SerialTakenDetail = z.object({ serials: z.array(z.string()) });
export type SerialTakenDetail = z.infer<typeof SerialTakenDetail>;

/** One step of a unit's life: a ledger row with its document and the other party. */
export const UnitHistoryEntry = z.object({
  id: Uuid,
  created_at: IsoTimestamp,
  business_date: BusinessDate,
  type: StockMovementType,
  quantity: z.number().int(),
  branch_id: Uuid,
  branch_name: z.string(),
  source_type: z.string(),
  source_id: Uuid,
  source_number: z.string().nullable(),
  /** The customer, the supplier, or "from → to" for a transfer. */
  party_name: z.string().nullable(),
  reason: AdjustmentReason.nullable(),
  created_by_name: z.string().nullable(),
});
export type UnitHistoryEntry = z.infer<typeof UnitHistoryEntry>;

export const UnitSummary = z.object({
  id: Uuid,
  serial: z.string(),
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  branch_id: Uuid,
  branch_name: z.string(),
  status: UnitStatus,
});
export type UnitSummary = z.infer<typeof UnitSummary>;

/** `GET /api/units/:id` and `/api/units/find`: the unit and its history, oldest first. */
export const UnitDetail = UnitSummary.extend({
  cost: Money,
  created_at: IsoTimestamp,
  purchase_invoice_id: Uuid.nullable(),
  purchase_invoice_number: z.string().nullable(),
  supplier_name: z.string().nullable(),
  history: z.array(UnitHistoryEntry),
});
export type UnitDetail = z.infer<typeof UnitDetail>;

export const UnitList = paginated(UnitSummary);
export type UnitList = z.infer<typeof UnitList>;

/** `GET /api/units`: serial prefix search in the caller's branches. */
export const UnitSearchQuery = PaginationQuery.extend({
  search: z
    .string()
    .trim()
    .max(64)
    .optional()
    .transform((v) => (v ? v : undefined)),
  status: UnitStatus.optional(),
  branch_id: Uuid.optional(),
}).strict();
export type UnitSearchQuery = z.infer<typeof UnitSearchQuery>;

/** `GET /api/units/find?serial=`: the exact serial, as scanned. */
export const UnitFindQuery = z.object({ serial: z.string().trim().min(1).max(64) }).strict();
export type UnitFindQuery = z.infer<typeof UnitFindQuery>;

export const UnitIdParams = z.object({ id: Uuid }).strict();
export type UnitIdParams = z.infer<typeof UnitIdParams>;
