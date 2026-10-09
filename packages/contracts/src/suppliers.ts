import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';

/**
 * U01 suppliers (D53). `balance` is what the shop owes the supplier (positive = owed), from
 * `v_supplier_balances`: approved invoices − credit returns − payments that are neither a reversal
 * nor reversed. `archived_at` is how archiving shows; archived suppliers stay readable.
 */
export const SupplierStatus = z.enum(['active', 'archived', 'all']);
export type SupplierStatus = z.infer<typeof SupplierStatus>;

export const Supplier = z.object({
  id: Uuid,
  name: z.string(),
  phone: z.string().nullable(),
  tax_registration_no: z.string().nullable(),
  address: z.string().nullable(),
  payment_terms_days: z.number().int().nonnegative(),
  notes: z.string().nullable(),
  archived_at: IsoTimestamp.nullable(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
  balance: Money,
});
export type Supplier = z.infer<typeof Supplier>;
export const SupplierList = paginated(Supplier);
export type SupplierList = z.infer<typeof SupplierList>;

/** `search` matches the name (contains, any letter case) or a phone prefix. */
export const SupplierListQuery = PaginationQuery.extend({
  search: z
    .string()
    .trim()
    .max(100)
    .optional()
    .transform((v) => (v ? v : undefined)),
  status: SupplierStatus.default('active'),
}).strict();
export type SupplierListQuery = z.infer<typeof SupplierListQuery>;

/** After spaces and dashes are removed: an optional `+`, then 6-15 digits. */
export const SUPPLIER_PHONE_PATTERN = /^\+?[0-9]{6,15}$/;
export const SUPPLIER_TAX_NO_PATTERN = /^[0-9-]{9,20}$/;

/** Removes spaces and dashes, as the server stores phones. */
export const normalizeSupplierPhone = (v: string) => v.replace(/[\s-]/g, '');

const nullIfEmpty = (v: string | null) => (v === '' ? null : v);

const fields = {
  name: z.string().trim().min(1).max(150),
  /** Empty means no phone (null). */
  phone: z
    .string()
    .trim()
    .transform(normalizeSupplierPhone)
    .refine((v) => v === '' || SUPPLIER_PHONE_PATTERN.test(v), {
      message: 'Phone must be 6-15 digits, optionally starting with +',
    })
    .nullable()
    .transform(nullIfEmpty),
  tax_registration_no: z
    .string()
    .trim()
    .refine((v) => v === '' || SUPPLIER_TAX_NO_PATTERN.test(v), {
      message: 'Tax number must be 9-20 digits or dashes',
    })
    .nullable()
    .transform(nullIfEmpty),
  address: z.string().trim().max(300).nullable().transform(nullIfEmpty),
  payment_terms_days: z.number().int().min(0).max(365),
  notes: z.string().trim().max(1000).nullable().transform(nullIfEmpty),
};

export const SupplierCreateBody = z
  .object({
    name: fields.name,
    phone: fields.phone.optional(),
    tax_registration_no: fields.tax_registration_no.optional(),
    address: fields.address.optional(),
    payment_terms_days: fields.payment_terms_days.default(0),
    notes: fields.notes.optional(),
  })
  .strict();
export type SupplierCreateBody = z.infer<typeof SupplierCreateBody>;
export type SupplierCreateInput = z.input<typeof SupplierCreateBody>;

/** Any create field; at least one. */
export const SupplierUpdateBody = z
  .object(fields)
  .partial()
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to change' });
export type SupplierUpdateBody = z.infer<typeof SupplierUpdateBody>;
export type SupplierUpdateInput = z.input<typeof SupplierUpdateBody>;

export const SupplierIdParams = z.object({ id: Uuid }).strict();
export type SupplierIdParams = z.infer<typeof SupplierIdParams>;

/** Business dates; `from` must not be after `to`. Leaving `from` out starts at the first document. */
export const SupplierStatementQuery = z
  .object({ from: BusinessDate.optional(), to: BusinessDate.optional() })
  .strict()
  .refine((q) => q.from === undefined || q.to === undefined || q.from <= q.to, {
    message: '`from` must not be after `to`',
    path: ['from'],
  });
export type SupplierStatementQuery = z.infer<typeof SupplierStatementQuery>;

export const SupplierStatementRowKind = z.enum([
  'invoice',
  'payment',
  'payment_reversal',
  'return',
]);
export type SupplierStatementRowKind = z.infer<typeof SupplierStatementRowKind>;

export const PurchaseRefundMode = z.enum(['supplier_credit', 'cash']);
export type PurchaseRefundMode = z.infer<typeof PurchaseRefundMode>;

/**
 * One document on the statement. `debit` raises what the shop owes (an approved invoice, a payment
 * reversal); `credit` lowers it (a payment, a credit return). A cash return shows 0 and 0: the
 * supplier refunded money, so the balance doesn't move. `balance` is the running total after the row.
 */
export const SupplierStatementRow = z.object({
  date: BusinessDate,
  kind: SupplierStatementRowKind,
  document_id: Uuid,
  number: z.string(),
  reference: z.string().nullable(),
  branch_id: Uuid,
  refund_mode: PurchaseRefundMode.nullable(),
  debit: Money,
  credit: Money,
  balance: Money,
});
export type SupplierStatementRow = z.infer<typeof SupplierStatementRow>;

/**
 * Shop-wide (every branch). `opening_balance` is the net of the documents before `from` (0 without
 * it); `closing_balance` = opening + invoiced − paid − returned of the rows shown. `paid` is net of
 * reversals and `returned` counts credit returns only. Without dates the closing balance equals
 * `supplier.balance`.
 */
export const SupplierStatement = z.object({
  supplier: Supplier,
  from: BusinessDate.nullable(),
  to: BusinessDate.nullable(),
  opening_balance: Money,
  closing_balance: Money,
  totals: z.object({ invoiced: Money, paid: Money, returned: Money }),
  rows: z.array(SupplierStatementRow),
});
export type SupplierStatement = z.infer<typeof SupplierStatement>;
