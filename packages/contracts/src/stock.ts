import { z } from 'zod';
import { IsoTimestamp, BusinessDate, PaginationQuery, Uuid, paginated } from './common.js';

/** Values of `public.adjustment_reason`. `count` is set only by a posted stock count (I02). */
export const AdjustmentReason = z.enum(['damage', 'loss', 'found', 'correction', 'count', 'other']);
export type AdjustmentReason = z.infer<typeof AdjustmentReason>;

/**
 * I01 stock view (D47). One row per product and branch, read from `stock_levels` (kept from the
 * ledger by trigger): `available = on_hand − reserved`; `damaged` is the damaged stock state;
 * `in_transit` is sent-not-received transfer stock coming INTO the branch. `min_level` is the
 * product's min stock, or the shop's global minimum; `low` = available < min_level.
 */
export const StockRow = z.object({
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  barcode: z.string().nullable(),
  category_id: Uuid.nullable(),
  is_serialized: z.boolean(),
  archived_at: IsoTimestamp.nullable(),
  branch_id: Uuid,
  on_hand: z.number().int(),
  reserved: z.number().int().nonnegative(),
  available: z.number().int(),
  damaged: z.number().int(),
  in_transit: z.number().int().nonnegative(),
  min_level: z.number().int().nonnegative(),
  low: z.boolean(),
});
export type StockRow = z.infer<typeof StockRow>;
export const StockList = paginated(StockRow);
export type StockList = z.infer<typeof StockList>;

const QueryFlag = z.enum(['true', 'false']).transform((v) => v === 'true');

export const StockListQuery = PaginationQuery.extend({
  branch_id: Uuid.optional(),
  category_id: Uuid.optional(),
  include_subcategories: QueryFlag.default('true'),
  search: z
    .string()
    .trim()
    .max(100)
    .optional()
    .transform((v) => (v ? v : undefined)),
  low_only: QueryFlag.default('false'),
}).strict();
export type StockListQuery = z.infer<typeof StockListQuery>;

/** Values of `public.stock_movement_type`. */
export const StockMovementType = z.enum([
  'opening',
  'purchase_in',
  'purchase_return_out',
  'sale_out',
  'sale_return_in',
  'transfer_out',
  'transfer_in',
  'adjustment',
  'delivery_out',
  'claim_out',
  'claim_in',
]);
export type StockMovementType = z.infer<typeof StockMovementType>;
export const StockState = z.enum(['sellable', 'damaged']);
export type StockState = z.infer<typeof StockState>;

/**
 * One ledger movement (the I01 drill-down; I05 adds filters and document links). `balance_after`
 * is the running on-hand of that branch and stock state after this movement.
 */
export const StockMovement = z.object({
  id: Uuid,
  created_at: IsoTimestamp,
  business_date: BusinessDate,
  branch_id: Uuid,
  type: StockMovementType,
  stock_state: StockState,
  quantity: z.number().int(),
  balance_after: z.number().int(),
  serial: z.string().nullable(),
  source_type: z.string(),
  source_id: Uuid,
  /** I02: the source document's number and the adjustment reason (stock adjustments only for now). */
  source_number: z.string().nullable(),
  reason: AdjustmentReason.nullable(),
  reverses_movement_id: Uuid.nullable(),
  created_by_name: z.string().nullable(),
});
export type StockMovement = z.infer<typeof StockMovement>;
export const StockMovementList = paginated(StockMovement);
export type StockMovementList = z.infer<typeof StockMovementList>;

export const StockMovementsQuery = PaginationQuery.extend({
  product_id: Uuid,
  branch_id: Uuid.optional(),
}).strict();
export type StockMovementsQuery = z.infer<typeof StockMovementsQuery>;

// ---------------------------------------------------------------- I02 adjustments and counts (D48)

const MAX_QTY = 1_000_000;
const SearchText = z
  .string()
  .trim()
  .max(100)
  .optional()
  .transform((v) => (v ? v : undefined));

/** Adds an issue for every repeated product (+ unit) in a list of lines. */
function noDuplicateLines(
  lines: { product_id: string; unit_id?: string | null | undefined }[],
  ctx: z.RefinementCtx,
) {
  const seen = new Set<string>();
  lines.forEach((l, i) => {
    const key = `${l.product_id}/${l.unit_id ?? ''}`;
    if (seen.has(key)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['lines', i], message: 'Duplicate line' });
    }
    seen.add(key);
  });
}

/** The reasons a person picks; `count` comes only from a posted count. */
export const ManualAdjustmentReason = AdjustmentReason.exclude(['count']);
export type ManualAdjustmentReason = z.infer<typeof ManualAdjustmentReason>;

export const StockAdjustmentLineBody = z
  .object({
    product_id: Uuid,
    /** Required for a serialized product (the quantity is then ±1); not allowed otherwise. */
    unit_id: Uuid.nullish(),
    quantity: z
      .number()
      .int()
      .min(-MAX_QTY)
      .max(MAX_QTY)
      .refine((q) => q !== 0, 'Quantity can not be zero'),
  })
  .strict();
export type StockAdjustmentLineBody = z.infer<typeof StockAdjustmentLineBody>;

/**
 * `POST /api/stock/adjustments` (stock.adjust, `Idempotency-Key` header). damage and loss remove
 * stock, found adds it, correction and other go either way; other needs a note.
 */
export const StockAdjustmentCreateBody = z
  .object({
    branch_id: Uuid,
    reason: ManualAdjustmentReason,
    note: z
      .string()
      .trim()
      .max(500)
      .nullish()
      .transform((v) => (v ? v : undefined)),
    lines: z.array(StockAdjustmentLineBody).min(1).max(500),
  })
  .strict()
  .superRefine((b, ctx) => {
    if (b.reason === 'other' && !b.note) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['note'], message: 'A note is required' });
    }
    const wrong = b.lines.findIndex((l) =>
      b.reason === 'found'
        ? l.quantity < 0
        : (b.reason === 'damage' || b.reason === 'loss') && l.quantity > 0,
    );
    if (wrong >= 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['lines', wrong, 'quantity'],
        message: 'The reason does not allow this direction',
      });
    }
    noDuplicateLines(b.lines, ctx);
  });
export type StockAdjustmentCreateBody = z.infer<typeof StockAdjustmentCreateBody>;

export const StockAdjustmentLine = z.object({
  id: Uuid,
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  quantity: z.number().int(),
});
export type StockAdjustmentLine = z.infer<typeof StockAdjustmentLine>;

/** An adjustment in a list: header and totals (units in, units out). */
export const StockAdjustmentSummary = z.object({
  id: Uuid,
  number: z.string(),
  branch_id: Uuid,
  reason: AdjustmentReason,
  note: z.string().nullable(),
  count_id: Uuid.nullable(),
  count_number: z.string().nullable(),
  created_at: IsoTimestamp,
  created_by_name: z.string().nullable(),
  lines_count: z.number().int().nonnegative(),
  quantity_in: z.number().int().nonnegative(),
  quantity_out: z.number().int().nonnegative(),
});
export type StockAdjustmentSummary = z.infer<typeof StockAdjustmentSummary>;
export const StockAdjustment = StockAdjustmentSummary.extend({
  lines: z.array(StockAdjustmentLine),
});
export type StockAdjustment = z.infer<typeof StockAdjustment>;
export const StockAdjustmentList = paginated(StockAdjustmentSummary);
export type StockAdjustmentList = z.infer<typeof StockAdjustmentList>;

export const StockAdjustmentListQuery = PaginationQuery.extend({
  branch_id: Uuid.optional(),
  reason: AdjustmentReason.optional(),
}).strict();
export type StockAdjustmentListQuery = z.infer<typeof StockAdjustmentListQuery>;

/** `:id` of an adjustment or a count. */
export const StockDocumentIdParams = z.object({ id: Uuid }).strict();
export type StockDocumentIdParams = z.infer<typeof StockDocumentIdParams>;

/** Values of `public.count_status`. */
export const StockCountStatus = z.enum(['open', 'posted', 'cancelled']);
export type StockCountStatus = z.infer<typeof StockCountStatus>;

/**
 * A count sheet. While it is open the summary uses the live stock as "expected", so
 * `quantity_in` / `quantity_out` are what posting would change; after posting, the stored numbers.
 */
export const StockCount = z.object({
  id: Uuid,
  number: z.string(),
  branch_id: Uuid,
  category_id: Uuid.nullable(),
  category_name: z.string().nullable(),
  status: StockCountStatus,
  created_at: IsoTimestamp,
  created_by_name: z.string().nullable(),
  posted_at: IsoTimestamp.nullable(),
  posted_by_name: z.string().nullable(),
  adjustment_id: Uuid.nullable(),
  adjustment_number: z.string().nullable(),
  lines_total: z.number().int().nonnegative(),
  lines_counted: z.number().int().nonnegative(),
  lines_different: z.number().int().nonnegative(),
  quantity_in: z.number().int().nonnegative(),
  quantity_out: z.number().int().nonnegative(),
});
export type StockCount = z.infer<typeof StockCount>;
export const StockCountList = paginated(StockCount);
export type StockCountList = z.infer<typeof StockCountList>;

export const StockCountLine = z.object({
  id: Uuid,
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  barcode: z.string().nullable(),
  is_serialized: z.boolean(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  expected_qty: z.number().int().nonnegative(),
  /** null = not counted yet. */
  counted_qty: z.number().int().nonnegative().nullable(),
  /** counted − expected; null while not counted. */
  difference: z.number().int().nullable(),
});
export type StockCountLine = z.infer<typeof StockCountLine>;

/** `GET /api/stock/counts/:id`: the count and one page of its lines. */
export const StockCountDetail = StockCount.extend({ lines: paginated(StockCountLine) });
export type StockCountDetail = z.infer<typeof StockCountDetail>;

export const StockCountLineFilter = z.enum(['all', 'uncounted', 'different']);
export type StockCountLineFilter = z.infer<typeof StockCountLineFilter>;

export const StockCountDetailQuery = PaginationQuery.extend({
  filter: StockCountLineFilter.default('all'),
  search: SearchText,
}).strict();
export type StockCountDetailQuery = z.infer<typeof StockCountDetailQuery>;

export const StockCountListQuery = PaginationQuery.extend({
  branch_id: Uuid.optional(),
  status: StockCountStatus.optional(),
}).strict();
export type StockCountListQuery = z.infer<typeof StockCountListQuery>;

/** `POST /api/stock/counts` (stock.count, `Idempotency-Key`): no category = the whole branch. */
export const StockCountCreateBody = z
  .object({ branch_id: Uuid, category_id: Uuid.nullish() })
  .strict();
export type StockCountCreateBody = z.infer<typeof StockCountCreateBody>;

export const StockCountLineBody = z
  .object({
    product_id: Uuid,
    unit_id: Uuid.nullish(),
    /** null clears the line (not counted). A unit is 0 or 1. */
    counted_qty: z.number().int().min(0).max(MAX_QTY).nullable(),
  })
  .strict();
export type StockCountLineBody = z.infer<typeof StockCountLineBody>;

/** `PUT /api/stock/counts/:id/lines`: counted quantities, at most 500 per call. */
export const StockCountLinesBody = z
  .object({ lines: z.array(StockCountLineBody).min(1).max(500) })
  .strict()
  .superRefine((b, ctx) => noDuplicateLines(b.lines, ctx));
export type StockCountLinesBody = z.infer<typeof StockCountLinesBody>;

/** `POST /api/stock/counts/:id/scan`: a serial counts its unit; a barcode or SKU adds one. */
export const StockCountScanBody = z.object({ code: z.string().trim().min(1).max(100) }).strict();
export type StockCountScanBody = z.infer<typeof StockCountScanBody>;

/** `POST /api/stock/counts/:id/post` (`Idempotency-Key`). */
export const StockCountPostBody = z
  .object({ uncounted_as_zero: z.boolean().default(false) })
  .strict();
export type StockCountPostBody = z.infer<typeof StockCountPostBody>;

// ---------------------------------------------------------------- I03 branch transfers (D49)

/** Values of `public.transfer_status`. */
export const TransferStatus = z.enum([
  'draft',
  'sent',
  'received',
  'partially_received',
  'cancelled',
]);
export type TransferStatus = z.infer<typeof TransferStatus>;

/** What did not arrive in full is written off at the destination with this reason. */
export const TransferDiscrepancyReason = z.enum(['loss', 'damage']);
export type TransferDiscrepancyReason = z.infer<typeof TransferDiscrepancyReason>;

export const StockTransferLineBody = z
  .object({
    product_id: Uuid,
    /** Required for a serialized product (a unit in stock in the source branch, quantity 1). */
    unit_id: Uuid.nullish(),
    quantity: z.number().int().min(1).max(MAX_QTY),
  })
  .strict();
export type StockTransferLineBody = z.infer<typeof StockTransferLineBody>;

const TransferLines = z.array(StockTransferLineBody).min(1).max(500);
const TransferNotes = z
  .string()
  .trim()
  .max(500)
  .nullish()
  .transform((v) => (v ? v : undefined));

/** `POST /api/stock/transfers` (stock.transfer_send, `Idempotency-Key`): a draft. */
export const StockTransferCreateBody = z
  .object({
    from_branch_id: Uuid,
    to_branch_id: Uuid,
    notes: TransferNotes,
    lines: TransferLines,
  })
  .strict()
  .superRefine((b, ctx) => {
    if (b.from_branch_id === b.to_branch_id) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['to_branch_id'],
        message: 'Choose another branch',
      });
    }
    noDuplicateLines(b.lines, ctx);
  });
export type StockTransferCreateBody = z.infer<typeof StockTransferCreateBody>;

/** `PUT /api/stock/transfers/:id`: replaces the notes and lines of a draft. */
export const StockTransferUpdateBody = z
  .object({ notes: TransferNotes, lines: TransferLines })
  .strict()
  .superRefine((b, ctx) => noDuplicateLines(b.lines, ctx));
export type StockTransferUpdateBody = z.infer<typeof StockTransferUpdateBody>;

/** One line that did not arrive in full: the quantity that did, and why the rest didn't. */
export const StockTransferReceiveLine = z
  .object({
    line_id: Uuid,
    qty_received: z.number().int().min(0).max(MAX_QTY),
    reason: TransferDiscrepancyReason,
  })
  .strict();
export type StockTransferReceiveLine = z.infer<typeof StockTransferReceiveLine>;

/** `POST /api/stock/transfers/:id/receive` (stock.transfer_receive): only the shortages. */
export const StockTransferReceiveBody = z
  .object({ lines: z.array(StockTransferReceiveLine).max(500).default([]) })
  .strict()
  .superRefine((b, ctx) => {
    const seen = new Set<string>();
    b.lines.forEach((l, i) => {
      if (seen.has(l.line_id)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['lines', i],
          message: 'Duplicate line',
        });
      }
      seen.add(l.line_id);
    });
  });
export type StockTransferReceiveBody = z.infer<typeof StockTransferReceiveBody>;

export const StockTransferLine = z.object({
  id: Uuid,
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  is_serialized: z.boolean(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  qty_sent: z.number().int().positive(),
  qty_received: z.number().int().nonnegative().nullable(),
  discrepancy_reason: z.string().nullable(),
});
export type StockTransferLine = z.infer<typeof StockTransferLine>;

/** A transfer in a list: header, totals and the adjustments its receipt wrote off. */
export const StockTransferSummary = z.object({
  id: Uuid,
  number: z.string(),
  from_branch_id: Uuid,
  to_branch_id: Uuid,
  /** Names too: a receiver may not work in the source branch. */
  from_branch_name: z.string(),
  to_branch_name: z.string(),
  status: TransferStatus,
  notes: z.string().nullable(),
  created_at: IsoTimestamp,
  created_by_name: z.string().nullable(),
  sent_at: IsoTimestamp.nullable(),
  sent_by_name: z.string().nullable(),
  received_at: IsoTimestamp.nullable(),
  received_by_name: z.string().nullable(),
  lines_count: z.number().int().nonnegative(),
  quantity_sent: z.number().int().nonnegative(),
  quantity_received: z.number().int().nonnegative().nullable(),
  adjustments: z.array(z.object({ id: Uuid, number: z.string(), reason: AdjustmentReason })),
});
export type StockTransferSummary = z.infer<typeof StockTransferSummary>;
export const StockTransfer = StockTransferSummary.extend({ lines: z.array(StockTransferLine) });
export type StockTransfer = z.infer<typeof StockTransfer>;
export const StockTransferList = paginated(StockTransferSummary);
export type StockTransferList = z.infer<typeof StockTransferList>;

export const StockTransferListQuery = PaginationQuery.extend({
  /** Transfers out of OR into this branch. */
  branch_id: Uuid.optional(),
  status: TransferStatus.optional(),
}).strict();
export type StockTransferListQuery = z.infer<typeof StockTransferListQuery>;

/** `GET /api/stock/transfers/destinations` (stock.transfer_send): every active branch of the shop. */
export const TransferDestination = z.object({ id: Uuid, code: z.string(), name: z.string() });
export type TransferDestination = z.infer<typeof TransferDestination>;
export const TransferDestinationList = z.array(TransferDestination);
export type TransferDestinationList = z.infer<typeof TransferDestinationList>;
