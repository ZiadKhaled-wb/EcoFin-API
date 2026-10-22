import { z } from 'zod';
import { PositiveMoney } from './cash.js';
import { BusinessDate, IsoTimestamp, MONEY_PATTERN, Money, Uuid } from './common.js';
import { Discount, DiscountReason, SaleLines, SalePayments } from './sales.js';

/**
 * S05 returns and exchanges (D88). Goods come back against the original sale, in the caller's
 * open shift at the sale's branch. Amounts come from the stored sale line (a line returned in
 * pieces gives back exactly its total and its VAT); the client sends what comes back and the
 * total it showed (`expected_total`, PRICE_CHANGED otherwise). Money goes back by the sale's own
 * methods (up to what each paid) or as store credit. An installment sale's return lowers what is
 * still owed (a new schedule version: the same installments, each smaller); only an overpaid part
 * is paid back. An exchange is a return and a new sale posted together.
 * Words: profit (ربح), installment price; never interest.
 */

const NonNegativeMoney = Money.refine((v) => !v.startsWith('-'), 'Must not be negative');
const Count = z.number().int().nonnegative();

export const RETURN_KINDS = ['return', 'exchange'] as const;
export const ReturnKind = z.enum(RETURN_KINDS);
export type ReturnKind = z.infer<typeof ReturnKind>;

/** Every return document kind, voids (S07) included. */
export const SalesReturnKind = z.enum(['return', 'void', 'exchange']);
export type SalesReturnKind = z.infer<typeof SalesReturnKind>;

export const RETURN_CONDITIONS = ['resellable', 'damaged'] as const;
export const ReturnCondition = z.enum(RETURN_CONDITIONS);
export type ReturnCondition = z.infer<typeof ReturnCondition>;

export const RefundMethod = z.enum([
  'cash',
  'bank_transfer',
  'store_credit',
  'contract_adjustment',
]);
export type RefundMethod = z.infer<typeof RefundMethod>;

/** The reason: 3-200 characters (REASON_REQUIRED). */
export const RETURN_REASON_MAX_LENGTH = 200;
export const ReturnReason = z.string().trim().min(3).max(RETURN_REASON_MAX_LENGTH);

/** One sale line coming back; a serialized line names its own unit, one at a time. */
export const ReturnLineInput = z
  .object({
    sale_line_id: Uuid,
    unit_id: Uuid.optional(),
    quantity: z.number().int().min(1).max(100_000),
    condition: ReturnCondition.default('resellable'),
  })
  .strict()
  .refine((l) => l.unit_id === undefined || l.quantity === 1, {
    message: 'A serial comes back one at a time',
    path: ['quantity'],
  });
export type ReturnLineInput = z.infer<typeof ReturnLineInput>;

export const ReturnLines = z
  .array(ReturnLineInput)
  .min(1)
  .max(200)
  .superRefine((lines, ctx) => {
    const seen = new Set<string>();
    lines.forEach((l, i) => {
      if (seen.has(l.sale_line_id)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: [i, 'sale_line_id'],
          message: 'A line appears once',
        });
      }
      seen.add(l.sale_line_id);
    });
  });

/**
 * How money goes back: cash from the caller's drawer, a bank transfer from a bank the sale was
 * paid into (with its reference), or store credit (the sale's customer).
 */
export const RefundLineInput = z.discriminatedUnion('method', [
  z.object({ method: z.literal('cash'), amount: PositiveMoney }).strict(),
  z
    .object({
      method: z.literal('bank_transfer'),
      amount: PositiveMoney,
      cash_account_id: Uuid,
      reference: z.string().trim().min(1).max(100),
    })
    .strict(),
  z.object({ method: z.literal('store_credit'), amount: PositiveMoney }).strict(),
]);
export type RefundLineInput = z.infer<typeof RefundLineInput>;

/** 0-5 lines (none when the whole credit goes to the contract); one cash, one store credit. */
export const RefundLines = z
  .array(RefundLineInput)
  .max(5)
  .superRefine((lines, ctx) => {
    const count = { cash: 0, bank_transfer: 0, store_credit: 0 };
    lines.forEach((l) => (count[l.method] += 1));
    if (count.cash > 1 || count.store_credit > 1) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'At most one cash and one store credit line',
      });
    }
  });

/** The exchange's new sale: the S01-S03 sale body, without the customer (the original's). */
export const ExchangeNewSaleInput = z
  .object({
    lines: SaleLines,
    expected_total: NonNegativeMoney.optional(),
    payments: SalePayments.optional(),
    sale_discount: Discount.optional(),
    discount_reason: DiscountReason.optional(),
    discount_approval_id: Uuid.optional(),
  })
  .strict();
export type ExchangeNewSaleInput = z.infer<typeof ExchangeNewSaleInput>;

const bodyShape = {
  sale_id: Uuid,
  kind: ReturnKind.default('return'),
  lines: ReturnLines,
  /** S12: a warranty claim open on a returned line lifts the return period and closes. */
  warranty_claim_id: Uuid.optional(),
  new_sale: ExchangeNewSaleInput.optional(),
};

function checkExchange(
  body: { kind: ReturnKind; new_sale?: ExchangeNewSaleInput | undefined },
  ctx: z.RefinementCtx,
) {
  if ((body.kind === 'exchange') !== (body.new_sale !== undefined)) {
    ctx.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['new_sale'],
      message: 'An exchange, and only an exchange, has a new sale',
    });
  }
}

/** `POST /api/returns/quote` (refund.create): checked and computed, nothing written. */
export const SalesReturnQuoteBody = z
  .object({
    ...bodyShape,
    refunds: RefundLines.optional(),
    reason: z.string().trim().max(RETURN_REASON_MAX_LENGTH).optional(),
    expected_total: NonNegativeMoney.optional(),
  })
  .strict()
  .superRefine(checkExchange);
export type SalesReturnQuoteBody = z.infer<typeof SalesReturnQuoteBody>;

/**
 * `POST /api/returns` (refund.create, `Idempotency-Key` header). The refund lines add up to what
 * goes back (PAYMENT_TOTAL_MISMATCH): the return's total, an installment sale's overpaid part, or
 * an exchange's credit left after the new sale. The exchange's new sale carries its own total.
 */
export const SalesReturnCreateBody = z
  .object({
    ...bodyShape,
    refunds: RefundLines.default([]),
    reason: ReturnReason,
    expected_total: NonNegativeMoney,
  })
  .strict()
  .superRefine(checkExchange)
  .superRefine((body, ctx) => {
    if (body.new_sale !== undefined && body.new_sale.expected_total === undefined) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['new_sale', 'expected_total'],
        message: 'The new sale needs the total the customer saw',
      });
    }
  });
export type SalesReturnCreateBody = z.infer<typeof SalesReturnCreateBody>;
export type SalesReturnCreateInput = z.input<typeof SalesReturnCreateBody>;

export const ReturnIdParams = z.object({ id: Uuid }).strict();
export type ReturnIdParams = z.infer<typeof ReturnIdParams>;

const Ref = z.object({ id: Uuid, name: z.string() });
const Person = z.object({ id: Uuid.nullable(), name: z.string().nullable() });
const Names = {
  product_id: Uuid,
  sku: z.string(),
  name_ar: z.string(),
  name_en: z.string().nullable(),
};

/** A refund line as computed (the drawer for cash, the bank for a transfer). */
export const RefundLine = z.object({
  method: z.enum(['cash', 'bank_transfer', 'store_credit']),
  amount: Money,
  cash_account_id: Uuid.nullable(),
  reference: z.string().nullable(),
});
export type RefundLine = z.infer<typeof RefundLine>;

/** By method: what the sale took less what earlier returns gave back (the refund caps). */
export const RefundableByMethod = z.object({
  cash: Money,
  bank_transfer: Money,
  store_credit: Money,
});
export type RefundableByMethod = z.infer<typeof RefundableByMethod>;

/** An installment sale's side of a return (rule 7 of D88). */
export const ReturnContractPlan = z.object({
  contract_id: Uuid,
  number: z.string(),
  status_before: z.string(),
  status_after: z.string(),
  version_before: z.number().int().positive(),
  remaining_before: Money,
  /** The returned goods' share of the profit. */
  profit_share: Money,
  /** Returned cash price + profit share. */
  credit: Money,
  /** What the credit took off the contract. */
  applied: Money,
  remaining_after: Money,
  principal_after: Money,
  profit_after: Money,
  /** credit - applied: paid back by the refund lines. */
  overpaid: Money,
  installments_left: Count,
  installment_amount: Money.nullable(),
  lines: z.array(
    z.object({
      seq: z.number().int().positive(),
      due_date: BusinessDate,
      principal: Money,
      profit: Money,
      amount: Money,
    }),
  ),
});
export type ReturnContractPlan = z.infer<typeof ReturnContractPlan>;

export const SalesReturnQuoteLine = z.object({
  ...Names,
  sale_line_id: Uuid,
  line_no: z.number().int().positive(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  quantity: z.number().int().positive(),
  condition: ReturnCondition,
  refund_amount: Money,
  tax_amount: Money,
});

export const SalesReturnQuote = z.object({
  sale_id: Uuid,
  sale_number: z.string(),
  kind: ReturnKind,
  lines: z.array(SalesReturnQuoteLine),
  subtotal: Money,
  tax_total: Money,
  total: Money,
  deadline: BusinessDate,
  /** The owner returns after the period. */
  period_override: z.boolean(),
  warranty_claim_id: Uuid.nullable(),
  contract: ReturnContractPlan.nullable(),
  /** What the refund lines must add up to. */
  refund_due: Money,
  refunds: z.array(RefundLine),
  /** A cash sale's refund caps; null on an installment sale. */
  refundable: RefundableByMethod.nullable(),
  exchange: z
    .object({
      new_total: Money,
      credit_used: Money,
      /** What the new sale's payment lines must cover. */
      to_pay: Money,
    })
    .nullable(),
});
export type SalesReturnQuote = z.infer<typeof SalesReturnQuote>;

/** `GET /api/sales/:id/returnable`: what can still come back. */
export const SaleReturnableLine = z.object({
  ...Names,
  sale_line_id: Uuid,
  line_no: z.number().int().positive(),
  is_serialized: z.boolean(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  sold: z.number().int().positive(),
  returned: Count,
  returnable: Count,
  unit_price: Money,
  line_total: Money,
  tax_amount: Money,
  refunded: Money,
  /** An open warranty claim on the line (S12): its refund lifts the period. */
  warranty_claim_id: Uuid.nullable(),
});
export type SaleReturnableLine = z.infer<typeof SaleReturnableLine>;

export const SALE_RETURN_BLOCKS = ['voided', 'fully_returned', 'contract_closed'] as const;
export const SaleReturnBlock = z.enum(SALE_RETURN_BLOCKS);
export type SaleReturnBlock = z.infer<typeof SaleReturnBlock>;

export const SaleReturnable = z.object({
  sale: z.object({
    id: Uuid,
    number: z.string(),
    business_date: BusinessDate,
    branch_id: Uuid,
    total: Money,
    customer_id: Uuid.nullable(),
    customer_name: z.string().nullable(),
  }),
  lines: z.array(SaleReturnableLine),
  paid_by_method: RefundableByMethod,
  deadline: BusinessDate,
  period_passed: z.boolean(),
  can_pass_period: z.boolean(),
  contract: z
    .object({
      id: Uuid,
      number: z.string(),
      status: z.string(),
      remaining: Money,
      installments_left: Count,
    })
    .nullable(),
  blocked: SaleReturnBlock.nullable(),
});
export type SaleReturnable = z.infer<typeof SaleReturnable>;

export const SalesReturnLine = z.object({
  ...Names,
  id: Uuid,
  sale_line_id: Uuid,
  line_no: z.number().int().positive(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  quantity: z.number().int().positive(),
  condition: ReturnCondition,
  refund_amount: Money,
  tax_amount: Money,
  tax_rate: z.string(),
});
export type SalesReturnLine = z.infer<typeof SalesReturnLine>;

export const SalesReturnRefund = z.object({
  id: Uuid,
  number: z.string(),
  method: z.enum(['cash', 'bank_transfer', 'store_credit']),
  amount: Money,
  cash_account_id: Uuid.nullable(),
  cash_account_name: z.string().nullable(),
  reference: z.string().nullable(),
  /** The drawer pair of an exchange (the credit used for the new sale), not money leaving. */
  exchange: z.boolean(),
});
export type SalesReturnRefund = z.infer<typeof SalesReturnRefund>;

/** A return document (`GET /api/returns/:id`, `POST /api/returns`). */
export const SalesReturn = z.object({
  id: Uuid,
  number: z.string(),
  kind: SalesReturnKind,
  refund_method: RefundMethod,
  sale: z.object({ id: Uuid, number: z.string(), business_date: BusinessDate, total: Money }),
  branch: Ref,
  customer: Ref.nullable(),
  shift_id: Uuid.nullable(),
  subtotal: Money,
  tax_total: Money,
  total: Money,
  reason: z.string(),
  business_date: BusinessDate,
  created_at: IsoTimestamp,
  created_by: Person,
  lines: z.array(SalesReturnLine),
  refunds: z.array(SalesReturnRefund),
  contract_change: z
    .object({
      id: Uuid,
      contract_id: Uuid,
      contract_number: z.string(),
      old_version: z.number().int().positive(),
      new_version: z.number().int().positive().nullable(),
      remaining_after: Money,
      status_after: z.string(),
      credit: Money,
      profit_share: Money,
    })
    .nullable(),
  exchange_sale: z.object({ id: Uuid, number: z.string(), total: Money }).nullable(),
  fiscal: z
    .object({
      status: z.string(),
      eta_uuid: z.string().nullable(),
      qr_payload: z.string().nullable(),
      last_error: z.string().nullable(),
    })
    .nullable(),
  receipt_prints: Count,
  /** true when the same Idempotency-Key answered an earlier return. */
  replayed: z.boolean().optional(),
});
export type SalesReturn = z.infer<typeof SalesReturn>;

export const SalesReturnListQuery = z
  .object({
    from: BusinessDate.optional(),
    to: BusinessDate.optional(),
    branch_id: Uuid.optional(),
    sale_id: Uuid.optional(),
    customer_id: Uuid.optional(),
    kind: SalesReturnKind.optional(),
    page: z.coerce.number().int().min(1).default(1),
    page_size: z.coerce.number().int().min(1).max(100).default(20),
  })
  .strict()
  .refine((q) => !q.from || !q.to || q.from <= q.to, {
    message: 'Invalid date range',
    path: ['to'],
  });
export type SalesReturnListQuery = z.infer<typeof SalesReturnListQuery>;

export const SalesReturnSummary = z.object({
  id: Uuid,
  number: z.string(),
  kind: SalesReturnKind,
  refund_method: RefundMethod,
  sale_id: Uuid,
  sale_number: z.string(),
  branch: Ref,
  customer: Ref.nullable(),
  total: Money,
  reason: z.string(),
  business_date: BusinessDate,
  created_at: IsoTimestamp,
  created_by: Person,
});
export type SalesReturnSummary = z.infer<typeof SalesReturnSummary>;

export const SalesReturnListResponse = z.object({
  items: z.array(SalesReturnSummary),
  total_count: Count,
  page: z.number().int().positive(),
  page_size: z.number().int().positive(),
});
export type SalesReturnListResponse = z.infer<typeof SalesReturnListResponse>;

/** `POST /api/returns/:id/receipt-prints`: the first print is the original, later ones copies. */
export const SalesReturnReceiptPrint = z.object({
  print_no: z.number().int().positive(),
  copy: z.boolean(),
});
export type SalesReturnReceiptPrint = z.infer<typeof SalesReturnReceiptPrint>;

/** S12 `POST /api/warranty/claims/:id/refund`: what the return form opens with. */
export const ClaimRefundTarget = z.object({
  claim_id: Uuid,
  sale_id: Uuid,
  sale_line_id: Uuid,
  unit_id: Uuid.nullable(),
});
export type ClaimRefundTarget = z.infer<typeof ClaimRefundTarget>;

/** Error details. */
export const SaleReturnQtyExceededDetail = z.object({ sale_line_id: Uuid, returnable: Count });
export const RefundExceedsPaidDetail = z.object({
  method: z.enum(['cash', 'bank_transfer']),
  available: z.string().regex(MONEY_PATTERN),
});
export const ReturnPeriodExpiredDetail = z.object({ deadline: BusinessDate });
