import { z } from 'zod';
import { Money, Uuid, IsoTimestamp } from './common.js';
import {
  allocateMoney,
  compareMoney,
  multiplyMoney,
  roundMoney,
  subtractMoney,
  sumMoney,
  taxForLine,
  type TaxBreakdown,
} from './money.js';
import { Percent } from './settings.js';

/**
 * T01 VAT engine (D41). The database function app.compute_document_tax is the source of truth
 * for documents the server posts; this is the same calculation for screens (POS preview, forms).
 * Both run the golden cases in supabase/tests/fixtures/t01_tax_cases.json and must agree exactly.
 *
 * Per line: amount = unit price x quantity - line discount - its share of the document discount
 * (largest remainder, by amount after line discount). Tax per line (F12 / D31): prices with VAT
 * -> net = round(amount / (1 + rate%)), tax = amount - net; prices without VAT -> tax =
 * round(amount x rate%). Totals are sums of the rounded lines, never re-taxed.
 */

export const TAX_KINDS = ['standard', 'zero', 'exempt'] as const;
export const TaxKind = z.enum(TAX_KINDS);
export type TaxKind = z.infer<typeof TaxKind>;

const NonNegativeMoney = Money.refine((v) => !v.startsWith('-'), 'Must not be negative');

export const TaxLineInput = z
  .object({
    unit_price: NonNegativeMoney,
    quantity: z.number().int().min(1),
    line_discount: NonNegativeMoney.default('0.00'),
    tax_rate: Percent,
  })
  .strict();
export type TaxLineInput = z.input<typeof TaxLineInput>;

export const TaxDocumentInput = z
  .object({
    prices_include_vat: z.boolean(),
    document_discount: NonNegativeMoney.default('0.00'),
    lines: z.array(TaxLineInput).min(1),
  })
  .strict();
export type TaxDocumentInput = z.input<typeof TaxDocumentInput>;

export interface TaxLineResult extends TaxBreakdown {
  /** unit price x quantity, before any discount. */
  line_amount: Money;
  /** Line discount plus its share of the document discount (what sale_lines.discount_amount stores). */
  discount_amount: Money;
  tax_rate: string;
}

export interface TaxDocumentResult {
  lines: TaxLineResult[];
  /** Sum of line amounts before discounts. */
  subtotal: Money;
  discount_total: Money;
  net_total: Money;
  tax_total: Money;
  /** What the customer pays: subtotal - discount_total (+ tax_total when prices exclude VAT). */
  total: Money;
}

export class TaxInputError extends Error {
  constructor(public readonly reason: 'LINE_DISCOUNT_TOO_LARGE' | 'DISCOUNT_TOO_LARGE') {
    super(reason);
    this.name = 'TaxInputError';
  }
}

export function computeDocumentTax(input: TaxDocumentInput): TaxDocumentResult {
  const doc = TaxDocumentInput.parse(input);
  const amounts = doc.lines.map((l) => multiplyMoney(roundMoney(l.unit_price), l.quantity));
  const afterLine = doc.lines.map((l, i) => {
    if (compareMoney(roundMoney(l.line_discount), amounts[i]!) > 0)
      throw new TaxInputError('LINE_DISCOUNT_TOO_LARGE');
    return subtractMoney(amounts[i]!, roundMoney(l.line_discount));
  });
  const base = sumMoney(afterLine);
  const docDiscount = roundMoney(doc.document_discount);
  if (compareMoney(docDiscount, base) > 0) throw new TaxInputError('DISCOUNT_TOO_LARGE');
  const shares =
    compareMoney(docDiscount, '0.00') === 0
      ? afterLine.map(() => '0.00')
      : allocateMoney(docDiscount, afterLine);

  const lines = doc.lines.map((l, i): TaxLineResult => {
    const amount = subtractMoney(afterLine[i]!, shares[i]!);
    return {
      line_amount: amounts[i]!,
      discount_amount: sumMoney([roundMoney(l.line_discount), shares[i]!]),
      tax_rate: l.tax_rate,
      ...taxForLine(amount, l.tax_rate, doc.prices_include_vat),
    };
  });
  return {
    lines,
    subtotal: sumMoney(amounts),
    discount_total: sumMoney(lines.map((l) => l.discount_amount)),
    net_total: sumMoney(lines.map((l) => l.net)),
    tax_total: sumMoney(lines.map((l) => l.tax)),
    total: sumMoney(lines.map((l) => l.gross)),
  };
}

/**
 * The exact tax to reverse when `quantity` units of an issued line come back. Proportional and
 * rounded half-up; the return that brings the line back to zero takes whatever is left, so all
 * returns of a line add up to the original line exactly.
 */
export function returnLineTax(
  original: TaxBreakdown & { quantity: number },
  alreadyReturned: TaxBreakdown & { quantity: number },
  quantity: number,
): TaxBreakdown {
  if (!Number.isInteger(quantity) || quantity < 1) throw new RangeError('Quantity must be >= 1');
  const left = original.quantity - alreadyReturned.quantity;
  if (quantity > left) throw new RangeError('More than the line has left to return');
  if (quantity === left) {
    const gross = subtractMoney(original.gross, alreadyReturned.gross);
    const tax = subtractMoney(original.tax, alreadyReturned.tax);
    return { net: subtractMoney(gross, tax), tax, gross };
  }
  // Two-way largest remainder = round(m x quantity / original quantity) half-up (ties go to the
  // returned part), which is what SQL round(..., 2) gives for the same values.
  const part = (m: Money) =>
    allocateMoney(m, [String(quantity), String(original.quantity - quantity)])[0]!;
  const gross = part(original.gross);
  const tax = part(original.tax);
  return { net: subtractMoney(gross, tax), tax, gross };
}

export const TaxClass = z.object({
  id: Uuid,
  name: z.string(),
  kind: TaxKind,
  rate: Percent,
  eta_tax_type: z.string(),
  eta_subtype: z.string(),
  archived_at: IsoTimestamp.nullable(),
  updated_at: IsoTimestamp,
});
export type TaxClass = z.infer<typeof TaxClass>;
export const TaxClassList = z.array(TaxClass);

const taxClassFields = {
  name: z.string().trim().min(1).max(60),
  kind: TaxKind,
  rate: Percent,
  eta_tax_type: z.string().trim().min(1).max(10),
  eta_subtype: z.string().trim().min(1).max(10),
};
/** Zero-rated and exempt classes always have a 0% rate. */
const zeroUnlessStandard = (b: { kind?: TaxKind | undefined; rate?: string | undefined }) =>
  b.kind === undefined || b.kind === 'standard' || b.rate === undefined || Number(b.rate) === 0;

export const TaxClassCreateBody = z
  .object(taxClassFields)
  .strict()
  .refine(zeroUnlessStandard, { message: 'Zero-rated and exempt classes have a 0% rate' });
export type TaxClassCreateBody = z.infer<typeof TaxClassCreateBody>;

export const TaxClassUpdateBody = z
  .object(taxClassFields)
  .partial()
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to change' })
  .refine(zeroUnlessStandard, { message: 'Zero-rated and exempt classes have a 0% rate' });
export type TaxClassUpdateBody = z.infer<typeof TaxClassUpdateBody>;

export const TaxClassIdParams = z.object({ id: Uuid }).strict();
