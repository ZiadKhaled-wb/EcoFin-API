import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';
import { Serial } from './units.js';

/**
 * U02 purchase invoices (D54). A supplier's invoice is a draft until it is approved (stock in once,
 * serial units created, moving-average cost updated, supplier balance up by the total) or rejected.
 * Unit costs are entered BEFORE VAT; VAT comes from each line's tax class (the product's by default).
 */
export const PurchaseInvoiceStatus = z.enum(['draft', 'pending_approval', 'approved', 'rejected']);
export type PurchaseInvoiceStatus = z.infer<typeof PurchaseInvoiceStatus>;

/** Net unit cost: a non-negative decimal string with at most 2 decimals. */
export const UnitCost = Money.refine((v) => !v.startsWith('-'), 'Must not be negative');

const nullIfEmpty = (v: string | null) => (v === '' ? null : v);
/** The supplier's own invoice number; empty means none. */
const SupplierInvoiceNo = z.string().trim().max(40).nullable().transform(nullIfEmpty);

export const PurchaseInvoiceLineInput = z
  .object({
    product_id: Uuid,
    quantity: z.number().int().min(1).max(100_000),
    unit_cost: UnitCost,
    /** Defaults to the product's tax class. */
    tax_class_id: Uuid.optional(),
    /** Serialized products only: one serial per unit (may be added before approval). */
    serials: z.array(Serial).min(1).max(500).optional(),
  })
  .strict()
  .refine((l) => l.serials === undefined || l.serials.length === l.quantity, {
    message: 'One serial per unit',
    path: ['serials'],
  });
export type PurchaseInvoiceLineInput = z.infer<typeof PurchaseInvoiceLineInput>;
export type PurchaseInvoiceLineFormInput = z.input<typeof PurchaseInvoiceLineInput>;

const Lines = z
  .array(PurchaseInvoiceLineInput)
  .min(1)
  .max(200)
  .refine((lines) => new Set(lines.map((l) => l.product_id)).size === lines.length, {
    message: 'A product appears at most once',
  });

export const PurchaseInvoiceCreateBody = z
  .object({
    supplier_id: Uuid,
    branch_id: Uuid,
    supplier_invoice_no: SupplierInvoiceNo.optional(),
    /** Not in the future (checked by the server against the shop's date). */
    invoice_date: BusinessDate,
    lines: Lines,
  })
  .strict();
export type PurchaseInvoiceCreateBody = z.infer<typeof PurchaseInvoiceCreateBody>;
export type PurchaseInvoiceCreateInput = z.input<typeof PurchaseInvoiceCreateBody>;

/** Drafts only. The supplier and the branch are fixed at creation. */
export const PurchaseInvoiceUpdateBody = z
  .object({
    supplier_invoice_no: SupplierInvoiceNo.optional(),
    invoice_date: BusinessDate.optional(),
    lines: Lines.optional(),
  })
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to change' });
export type PurchaseInvoiceUpdateBody = z.infer<typeof PurchaseInvoiceUpdateBody>;
export type PurchaseInvoiceUpdateInput = z.input<typeof PurchaseInvoiceUpdateBody>;

export const PurchaseInvoiceRejectBody = z
  .object({ reason: z.string().trim().min(3).max(500) })
  .strict();
export type PurchaseInvoiceRejectBody = z.infer<typeof PurchaseInvoiceRejectBody>;

export const PurchaseInvoiceIdParams = z.object({ id: Uuid }).strict();
export type PurchaseInvoiceIdParams = z.infer<typeof PurchaseInvoiceIdParams>;

export const PurchaseInvoiceLine = z.object({
  id: Uuid,
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  is_serialized: z.boolean(),
  quantity: z.number().int().positive(),
  unit_cost: Money,
  tax_class_id: Uuid,
  /** Percent, e.g. "14.00". */
  tax_rate: z.string(),
  tax_amount: Money,
  /** quantity × unit_cost (before VAT). */
  net: Money,
  /** net + tax. */
  line_total: Money,
  serials: z.array(z.string()).nullable(),
  /** The serial units created by the approval (empty before). */
  unit_ids: z.array(Uuid),
});
export type PurchaseInvoiceLine = z.infer<typeof PurchaseInvoiceLine>;

const header = {
  id: Uuid,
  number: z.string(),
  supplier_id: Uuid,
  supplier_name: z.string(),
  branch_id: Uuid,
  supplier_invoice_no: z.string().nullable(),
  invoice_date: BusinessDate,
  status: PurchaseInvoiceStatus,
  subtotal: Money,
  tax_total: Money,
  total: Money,
  /** Approved invoices only: total − payments − credit returns. */
  outstanding: Money.nullable(),
  approved_by_name: z.string().nullable(),
  approved_at: IsoTimestamp.nullable(),
  rejected_reason: z.string().nullable(),
  created_by_name: z.string().nullable(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
};

export const PurchaseInvoice = z.object({ ...header, lines: z.array(PurchaseInvoiceLine) });
export type PurchaseInvoice = z.infer<typeof PurchaseInvoice>;

export const PurchaseInvoiceSummary = z.object({
  ...header,
  lines_count: z.number().int().nonnegative(),
});
export type PurchaseInvoiceSummary = z.infer<typeof PurchaseInvoiceSummary>;
export const PurchaseInvoiceList = paginated(PurchaseInvoiceSummary);
export type PurchaseInvoiceList = z.infer<typeof PurchaseInvoiceList>;

/** Only the caller's branches. search: the PI number or the supplier's invoice number. */
export const PurchaseInvoiceListQuery = PaginationQuery.extend({
  supplier_id: Uuid.optional(),
  branch_id: Uuid.optional(),
  status: PurchaseInvoiceStatus.optional(),
  from: BusinessDate.optional(),
  to: BusinessDate.optional(),
  search: z
    .string()
    .trim()
    .max(40)
    .optional()
    .transform((v) => (v ? v : undefined)),
})
  .strict()
  .refine((q) => q.from === undefined || q.to === undefined || q.from <= q.to, {
    message: '`from` must not be after `to`',
    path: ['from'],
  });
export type PurchaseInvoiceListQuery = z.infer<typeof PurchaseInvoiceListQuery>;

/** Details of SERIALS_REQUIRED: the serialized lines that still need their serials. */
export const SerialsRequiredDetail = z.object({ line_ids: z.array(Uuid) });
export type SerialsRequiredDetail = z.infer<typeof SerialsRequiredDetail>;
