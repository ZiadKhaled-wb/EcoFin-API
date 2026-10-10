import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';

/**
 * S01 sale core (D62). A cashier with an open shift turns a cart into a completed cash sale in
 * one request. Prices come from the server: the client sends what it wants to sell and the total
 * it showed the customer; the server prices the cart again and refuses a different total.
 */
const NonNegativeMoney = Money.refine((v) => !v.startsWith('-'), 'Must not be negative');

export const SaleLineInput = z
  .object({
    product_id: Uuid,
    quantity: z.number().int().min(1).max(100_000),
    /** Serialized products only: the exact unit (IMEI / serial) being sold. */
    unit_id: Uuid.optional(),
    /** Only read when it differs from the list price, and then it needs `price.override`. */
    unit_price: NonNegativeMoney.optional(),
  })
  .strict()
  .refine((l) => l.unit_id === undefined || l.quantity === 1, {
    message: 'A serial is sold one at a time',
    path: ['quantity'],
  });
export type SaleLineInput = z.infer<typeof SaleLineInput>;

/** A unit once; a product on one line, unless every one of its lines names a unit. */
function checkCart(lines: readonly SaleLineInput[], ctx: z.RefinementCtx) {
  const units = new Set<string>();
  const products = new Map<string, { count: number; withoutUnit: boolean }>();
  lines.forEach((l, i) => {
    if (l.unit_id !== undefined) {
      if (units.has(l.unit_id)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: [i, 'unit_id'],
          message: 'A unit appears at most once',
        });
      }
      units.add(l.unit_id);
    }
    const seen = products.get(l.product_id) ?? { count: 0, withoutUnit: false };
    seen.count += 1;
    seen.withoutUnit = seen.withoutUnit || l.unit_id === undefined;
    products.set(l.product_id, seen);
    if (seen.count > 1 && seen.withoutUnit) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: [i, 'product_id'],
        message: 'A product appears on one line',
      });
    }
  });
}
const SaleLines = z.array(SaleLineInput).min(1).max(100).superRefine(checkCart);

/** `POST /api/sales/quote` (sale.create): prices a cart, writes nothing. */
export const SaleQuoteBody = z.object({ lines: SaleLines, customer_id: Uuid.optional() }).strict();
export type SaleQuoteBody = z.infer<typeof SaleQuoteBody>;

/**
 * `POST /api/sales` (sale.create, `Idempotency-Key` header). `expected_total` is the total of the
 * quote the cashier confirmed: a different server total answers `PRICE_CHANGED`.
 */
export const SaleCreateBody = z
  .object({ lines: SaleLines, customer_id: Uuid.optional(), expected_total: NonNegativeMoney })
  .strict();
export type SaleCreateBody = z.infer<typeof SaleCreateBody>;
export type SaleCreateInput = z.input<typeof SaleCreateBody>;

export const SaleIdParams = z.object({ id: Uuid }).strict();
export type SaleIdParams = z.infer<typeof SaleIdParams>;

const lineBase = {
  product_id: Uuid,
  name_ar: z.string(),
  name_en: z.string().nullable(),
  sku: z.string(),
  is_serialized: z.boolean(),
  unit_id: Uuid.nullable(),
  serial: z.string().nullable(),
  quantity: z.number().int().positive(),
  /** What the line is sold at (with or without VAT, as `prices_include_vat` says). */
  unit_price: Money,
  /** Percent, e.g. "14.00". */
  tax_rate: z.string(),
  tax_amount: Money,
  /** What the customer pays for the line, VAT included. */
  line_total: Money,
};

export const SaleQuoteLine = z.object({
  ...lineBase,
  /** The product's price in the catalogue. */
  list_price: Money,
  /** True when `unit_price` is an override of the list price. */
  overridden: z.boolean(),
  /** Sellable stock of the product in the shift's branch right now (not reserved for the cart). */
  available: z.number().int(),
});
export type SaleQuoteLine = z.infer<typeof SaleQuoteLine>;

export const SaleQuote = z.object({
  prices_include_vat: z.boolean(),
  lines: z.array(SaleQuoteLine),
  subtotal: Money,
  tax_total: Money,
  total: Money,
});
export type SaleQuote = z.infer<typeof SaleQuote>;

export const SaleLine = z.object({
  ...lineBase,
  id: Uuid,
  line_no: z.number().int().positive(),
  warranty_until: BusinessDate.nullable(),
});
export type SaleLine = z.infer<typeof SaleLine>;

export const SalePaymentMethod = z.enum(['cash', 'bank_transfer', 'store_credit']);
export type SalePaymentMethod = z.infer<typeof SalePaymentMethod>;

export const SalePayment = z.object({
  id: Uuid,
  number: z.string(),
  method: SalePaymentMethod,
  amount: Money,
  cash_account_id: Uuid.nullable(),
  cash_account_name: z.string().nullable(),
  reference: z.string().nullable(),
});
export type SalePayment = z.infer<typeof SalePayment>;

export const Sale = z.object({
  id: Uuid,
  number: z.string(),
  branch_id: Uuid,
  shift_id: Uuid.nullable(),
  shift_number: z.string().nullable(),
  /** null = a walk-in customer. */
  customer_id: Uuid.nullable(),
  customer_name: z.string().nullable(),
  /** The shop's VAT mode when the sale was made (a snapshot). */
  prices_include_vat: z.boolean(),
  subtotal: Money,
  discount_total: Money,
  tax_total: Money,
  total: Money,
  business_date: BusinessDate,
  issued_at: IsoTimestamp,
  created_by_name: z.string().nullable(),
  lines: z.array(SaleLine),
  payments: z.array(SalePayment),
});
export type Sale = z.infer<typeof Sale>;

/** Details of `PRICE_CHANGED`: what the client expected and what the cart costs now. */
export const PriceChangedDetail = z.object({ expected_total: Money, total: Money });
export type PriceChangedDetail = z.infer<typeof PriceChangedDetail>;

/** Details of `OUT_OF_STOCK` from a sale: the first product the branch can't cover. */
export const OutOfStockDetail = z.object({
  product_id: Uuid,
  requested: z.number().int(),
  available: z.number().int(),
});
export type OutOfStockDetail = z.infer<typeof OutOfStockDetail>;
