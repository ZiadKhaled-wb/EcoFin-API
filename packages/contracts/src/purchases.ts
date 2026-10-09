import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';
import { Serial } from './units.js';
import { PurchaseRefundMode } from './suppliers.js';

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

/** U06 (D55): approval statuses (the baseline `approval_status`). */
export const PurchaseApprovalStatus = z.enum(['pending', 'approved', 'rejected', 'cancelled']);
export type PurchaseApprovalStatus = z.infer<typeof PurchaseApprovalStatus>;

/**
 * The owner's decision on an invoice above the shop's purchase approval threshold. `threshold` is
 * the one in force when the approval was requested; `note` is the owner's note or rejection reason.
 */
export const PurchaseApproval = z.object({
  id: Uuid,
  status: PurchaseApprovalStatus,
  amount: Money,
  threshold: Money.nullable(),
  requested_by_name: z.string().nullable(),
  requested_at: IsoTimestamp,
  decided_by_name: z.string().nullable(),
  decided_at: IsoTimestamp.nullable(),
  note: z.string().nullable(),
});
export type PurchaseApproval = z.infer<typeof PurchaseApproval>;

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
  /** U06: the latest approval of the invoice, if it ever waited for the owner. */
  approval: PurchaseApproval.nullable(),
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

/**
 * U06: approve body. A note is needed only when the owner decides an invoice that waits for them
 * (pending_approval); `{}` approves a draft.
 */
export const PurchaseInvoiceApproveBody = z
  .object({ note: z.string().trim().min(3).max(500).optional() })
  .strict();
export type PurchaseInvoiceApproveBody = z.infer<typeof PurchaseInvoiceApproveBody>;

export const PurchaseApprovalListItem = z.object({
  approval: PurchaseApproval,
  invoice: PurchaseInvoiceSummary,
});
export type PurchaseApprovalListItem = z.infer<typeof PurchaseApprovalListItem>;
export const PurchaseApprovalList = paginated(PurchaseApprovalListItem);
export type PurchaseApprovalList = z.infer<typeof PurchaseApprovalList>;

/** Approvals of the caller's branches (purchase.invoice_approve); waiting ones by default. */
export const PurchaseApprovalListQuery = PaginationQuery.extend({
  status: PurchaseApprovalStatus.default('pending'),
  branch_id: Uuid.optional(),
}).strict();
export type PurchaseApprovalListQuery = z.infer<typeof PurchaseApprovalListQuery>;

/** Details of SERIALS_REQUIRED: the serialized lines that still need their serials. */
export const SerialsRequiredDetail = z.object({ line_ids: z.array(Uuid) });
export type SerialsRequiredDetail = z.infer<typeof SerialsRequiredDetail>;

/**
 * U04 purchase returns (D57). Goods go back against an approved invoice, from its branch, at the
 * invoice's net unit cost; `supplier_credit` lowers the supplier balance, `cash` puts the refund
 * into a safe or bank (`cash_account_id`) and leaves the balance alone.
 */
export const PurchaseReturnLineInput = z
  .object({
    invoice_line_id: Uuid,
    /** Normal lines: how many go back. */
    quantity: z.number().int().min(1).max(1_000_000).optional(),
    /** Serialized lines: the exact units (created by this invoice line, in stock). */
    unit_ids: z.array(Uuid).min(1).max(500).optional(),
  })
  .strict()
  .refine((l) => (l.quantity === undefined) !== (l.unit_ids === undefined), {
    message: 'Give either quantity or unit_ids',
  })
  .refine((l) => !l.unit_ids || new Set(l.unit_ids).size === l.unit_ids.length, {
    message: 'A unit appears at most once',
    path: ['unit_ids'],
  });
export type PurchaseReturnLineInput = z.infer<typeof PurchaseReturnLineInput>;

/** `Idempotency-Key` header. `cash_account_id` is required for `cash` and forbidden otherwise. */
export const PurchaseReturnCreateBody = z
  .object({
    purchase_invoice_id: Uuid,
    refund_mode: PurchaseRefundMode,
    cash_account_id: Uuid.optional(),
    reason: z.string().trim().min(3).max(500),
    lines: z
      .array(PurchaseReturnLineInput)
      .min(1)
      .max(200)
      .refine((lines) => new Set(lines.map((l) => l.invoice_line_id)).size === lines.length, {
        message: 'A line appears at most once',
      }),
  })
  .strict()
  .refine((b) => (b.refund_mode === 'cash') === (b.cash_account_id !== undefined), {
    message: 'A cash refund needs an account; a supplier credit takes none',
    path: ['cash_account_id'],
  });
export type PurchaseReturnCreateBody = z.infer<typeof PurchaseReturnCreateBody>;
export type PurchaseReturnCreateInput = z.input<typeof PurchaseReturnCreateBody>;

export const PurchaseReturnIdParams = z.object({ id: Uuid }).strict();
export type PurchaseReturnIdParams = z.infer<typeof PurchaseReturnIdParams>;

export const PurchaseReturnLine = z.object({
  id: Uuid,
  invoice_line_id: Uuid,
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  quantity: z.number().int().positive(),
  unit_cost: Money,
  tax_amount: Money,
  net: Money,
  line_total: Money,
});
export type PurchaseReturnLine = z.infer<typeof PurchaseReturnLine>;

const returnHeader = {
  id: Uuid,
  number: z.string(),
  purchase_invoice_id: Uuid,
  invoice_number: z.string(),
  supplier_id: Uuid,
  supplier_name: z.string(),
  branch_id: Uuid,
  refund_mode: PurchaseRefundMode,
  cash_account_id: Uuid.nullable(),
  cash_account_name: z.string().nullable(),
  subtotal: Money,
  tax_total: Money,
  total: Money,
  reason: z.string(),
  business_date: BusinessDate,
  created_by_name: z.string().nullable(),
  created_at: IsoTimestamp,
};
export const PurchaseReturn = z.object({ ...returnHeader, lines: z.array(PurchaseReturnLine) });
export type PurchaseReturn = z.infer<typeof PurchaseReturn>;
export const PurchaseReturnSummary = z.object({
  ...returnHeader,
  lines_count: z.number().int().nonnegative(),
});
export type PurchaseReturnSummary = z.infer<typeof PurchaseReturnSummary>;
export const PurchaseReturnList = paginated(PurchaseReturnSummary);
export type PurchaseReturnList = z.infer<typeof PurchaseReturnList>;

export const PurchaseReturnListQuery = PaginationQuery.extend({
  supplier_id: Uuid.optional(),
  branch_id: Uuid.optional(),
  purchase_invoice_id: Uuid.optional(),
  from: BusinessDate.optional(),
  to: BusinessDate.optional(),
})
  .strict()
  .refine((q) => q.from === undefined || q.to === undefined || q.from <= q.to, {
    message: '`from` must not be after `to`',
    path: ['from'],
  });
export type PurchaseReturnListQuery = z.infer<typeof PurchaseReturnListQuery>;

/** What can still go back from an invoice: per line, and the units in stock in its branch. */
export const ReturnableLine = z.object({
  invoice_line_id: Uuid,
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  is_serialized: z.boolean(),
  purchased: z.number().int().positive(),
  returned: z.number().int().nonnegative(),
  returnable: z.number().int().nonnegative(),
  unit_cost: Money,
  units_in_stock: z.array(z.object({ unit_id: Uuid, serial: z.string() })),
});
export type ReturnableLine = z.infer<typeof ReturnableLine>;
export const ReturnableInvoice = z.object({
  invoice: PurchaseInvoiceSummary,
  lines: z.array(ReturnableLine),
});
export type ReturnableInvoice = z.infer<typeof ReturnableInvoice>;

/** Details of RETURN_QTY_EXCEEDED: the line and how many can still go back. */
export const ReturnQtyExceededDetail = z.object({
  invoice_line_id: Uuid,
  returnable: z.number().int().nonnegative(),
});
export type ReturnQtyExceededDetail = z.infer<typeof ReturnQtyExceededDetail>;

/** U04 decision 8 (also U03): an active safe or bank usable for a branch, with its balance. */
export const PayableCashAccount = z.object({
  id: Uuid,
  name: z.string(),
  kind: z.enum(['safe', 'bank']),
  branch_id: Uuid.nullable(),
  balance: Money,
});
export type PayableCashAccount = z.infer<typeof PayableCashAccount>;
export const PayableCashAccountList = z.object({ items: z.array(PayableCashAccount) });
export type PayableCashAccountList = z.infer<typeof PayableCashAccountList>;
export const PayableCashAccountQuery = z.object({ branch_id: Uuid }).strict();
export type PayableCashAccountQuery = z.infer<typeof PayableCashAccountQuery>;
