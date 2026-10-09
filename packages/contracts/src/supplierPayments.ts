import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';
import { PositiveMoney } from './cash.js';
import { compareMoney, sumMoney } from './money.js';

/**
 * U03 supplier payments (D58). A payment leaves an active safe or bank and is fully allocated to
 * the supplier's approved invoices: the given allocations, or oldest invoice first when none are
 * given. Never more than what is owed. The owner can reverse a payment with a reason.
 */
export const SupplierPaymentAllocationInput = z
  .object({ purchase_invoice_id: Uuid, amount: PositiveMoney })
  .strict();
export type SupplierPaymentAllocationInput = z.infer<typeof SupplierPaymentAllocationInput>;

/** `Idempotency-Key` header. Allocations, when given, add up to the amount, each invoice once. */
export const SupplierPaymentCreateBody = z
  .object({
    supplier_id: Uuid,
    branch_id: Uuid,
    cash_account_id: Uuid,
    amount: PositiveMoney,
    reference: z.string().trim().max(100).nullable().optional(),
    allocations: z
      .array(SupplierPaymentAllocationInput)
      .min(1)
      .max(100)
      .refine((a) => new Set(a.map((x) => x.purchase_invoice_id)).size === a.length, {
        message: 'An invoice appears at most once',
      })
      .optional(),
  })
  .strict()
  .refine(
    (b) =>
      !b.allocations ||
      compareMoney(sumMoney(b.allocations.map((a) => a.amount)), sumMoney([b.amount])) === 0,
    { message: 'The allocations must add up to the amount', path: ['allocations'] },
  );
export type SupplierPaymentCreateBody = z.infer<typeof SupplierPaymentCreateBody>;
export type SupplierPaymentCreateInput = z.input<typeof SupplierPaymentCreateBody>;

/** `Idempotency-Key` header. Owner only. */
export const SupplierPaymentReverseBody = z
  .object({ reason: z.string().trim().min(3).max(500) })
  .strict();
export type SupplierPaymentReverseBody = z.infer<typeof SupplierPaymentReverseBody>;

export const SupplierPaymentIdParams = z.object({ id: Uuid }).strict();
export type SupplierPaymentIdParams = z.infer<typeof SupplierPaymentIdParams>;

export const SupplierPaymentAllocation = z.object({
  purchase_invoice_id: Uuid,
  invoice_number: z.string(),
  amount: Money,
});
export type SupplierPaymentAllocation = z.infer<typeof SupplierPaymentAllocation>;

const paymentHeader = {
  id: Uuid,
  /** The receipt number (SP). A reversal has its own. */
  number: z.string(),
  supplier_id: Uuid,
  supplier_name: z.string(),
  branch_id: Uuid,
  cash_account_id: Uuid,
  cash_account_name: z.string(),
  amount: Money,
  reference: z.string().nullable(),
  business_date: BusinessDate,
  paid_at: IsoTimestamp,
  /** Set on a reversal: the payment it undoes. */
  reverses_payment_id: Uuid.nullable(),
  /** Set on a reversed payment: its reversal. */
  reversed_by_payment_id: Uuid.nullable(),
  /** The reversal's reason (null on a payment). */
  reason: z.string().nullable(),
  created_by_name: z.string().nullable(),
};
export const SupplierPayment = z.object({
  ...paymentHeader,
  /** Empty on a reversal. */
  allocations: z.array(SupplierPaymentAllocation),
});
export type SupplierPayment = z.infer<typeof SupplierPayment>;
export const SupplierPaymentSummary = z.object(paymentHeader);
export type SupplierPaymentSummary = z.infer<typeof SupplierPaymentSummary>;
export const SupplierPaymentList = paginated(SupplierPaymentSummary);
export type SupplierPaymentList = z.infer<typeof SupplierPaymentList>;

export const SupplierPaymentListQuery = PaginationQuery.extend({
  supplier_id: Uuid.optional(),
  branch_id: Uuid.optional(),
  from: BusinessDate.optional(),
  to: BusinessDate.optional(),
  /** `false`: only the payments that count (no reversals, no reversed payments). */
  include_reversals: z
    .union([z.boolean(), z.enum(['true', 'false']).transform((v) => v === 'true')])
    .default(true),
})
  .strict()
  .refine((q) => q.from === undefined || q.to === undefined || q.from <= q.to, {
    message: '`from` must not be after `to`',
    path: ['from'],
  });
export type SupplierPaymentListQuery = z.infer<typeof SupplierPaymentListQuery>;

/** An approved invoice a supplier is still owed on. The due date is for display only. */
export const OpenSupplierInvoice = z.object({
  purchase_invoice_id: Uuid,
  number: z.string(),
  supplier_invoice_no: z.string().nullable(),
  branch_id: Uuid,
  invoice_date: BusinessDate,
  due_date: BusinessDate,
  overdue: z.boolean(),
  total: Money,
  paid: Money,
  returned_credit: Money,
  outstanding: Money,
});
export type OpenSupplierInvoice = z.infer<typeof OpenSupplierInvoice>;
export const OpenSupplierInvoiceList = z.object({
  items: z.array(OpenSupplierInvoice),
  total_outstanding: Money,
});
export type OpenSupplierInvoiceList = z.infer<typeof OpenSupplierInvoiceList>;
export const OpenSupplierInvoiceQuery = z.object({ supplier_id: Uuid }).strict();
export type OpenSupplierInvoiceQuery = z.infer<typeof OpenSupplierInvoiceQuery>;

/**
 * Details of PAYMENT_EXCEEDS_OUTSTANDING: the invoice whose allocation is too big (absent or null
 * when the whole amount is more than the supplier is owed) and what is still owed there.
 */
export const PaymentExceedsOutstandingDetail = z.object({
  purchase_invoice_id: Uuid.nullable().optional(),
  outstanding: Money,
});
export type PaymentExceedsOutstandingDetail = z.infer<typeof PaymentExceedsOutstandingDetail>;
