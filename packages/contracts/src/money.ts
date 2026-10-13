import Big from 'big.js';
import { MONEY_PATTERN, type Money } from './common.js';

/*
 * F12 money rules: the one place where API and Web do money maths (D31).
 * - Amounts are decimal strings (the contract's `Money`), never JS numbers. big.js keeps them exact.
 * - One rounding rule: half-up (a half rounds away from zero) to 2 decimals.
 * - Tax is calculated and rounded per LINE; document totals are sums of the rounded line values,
 *   never recalculated from the totals (T01 "line-level calculation"). See `taxForLine` / `sumTaxLines`.
 * - Every result is a canonical `Money` string with exactly 2 decimals ("333.34", "0.00").
 */

/** Own constructor, so another module changing the global `Big` settings can't change ours. */
const Dec = Big();
Dec.DP = 20;
Dec.RM = Big.roundHalfUp;
Dec.strict = true; // a JS number passed in by mistake throws instead of being converted

type Dec = Big.Big;

export const MONEY_DECIMALS = 2;

/** "-12", "12.5", "0.125". No exponent, no spaces, no "+", no thousands separators. */
const DECIMAL_PATTERN = /^-?\d+(\.\d+)?$/;

function decimal(value: string, what: string): Dec {
  if (typeof value !== 'string' || !DECIMAL_PATTERN.test(value)) {
    throw new RangeError(`${what} must be a decimal string, got ${String(value)}`);
  }
  return Dec(value);
}

/** Inputs to add/subtract/sum must already be money (at most 2 decimals): rounding never hides in a sum. */
function money(value: string): Dec {
  if (typeof value !== 'string' || !MONEY_PATTERN.test(value)) {
    throw new RangeError(
      `Money must be a decimal string with at most 2 decimals, got ${String(value)}`,
    );
  }
  return Dec(value);
}

function percent(value: string): Dec {
  const p = decimal(value, 'Percent');
  if (p.lt('0') || p.gt('100'))
    throw new RangeError(`Percent must be between 0 and 100, got ${value}`);
  return p;
}

function count(value: number, what: string): number {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new RangeError(`${what} must be a whole number of at least 1, got ${String(value)}`);
  }
  return value;
}

/** Round half-up to 2 decimals and print canonically. Never "-0.00"; overflow of numeric(18,2) throws. */
function toMoney(value: Dec): Money {
  const rounded = value.round(MONEY_DECIMALS, Big.roundHalfUp);
  const text = rounded.eq('0') ? '0.00' : rounded.toFixed(MONEY_DECIMALS);
  if (!MONEY_PATTERN.test(text)) throw new RangeError(`Amount out of range for money: ${text}`);
  return text;
}

/** Any decimal string -> money, half-up: "2.345" -> "2.35", "-2.345" -> "-2.35", "-0.004" -> "0.00". */
export function roundMoney(value: string): Money {
  return toMoney(decimal(value, 'Amount'));
}

export function addMoney(a: Money, b: Money): Money {
  return toMoney(money(a).plus(money(b)));
}

export function subtractMoney(a: Money, b: Money): Money {
  return toMoney(money(a).minus(money(b)));
}

/** Sum of money values; an empty list is "0.00". */
export function sumMoney(values: readonly Money[]): Money {
  return toMoney(values.reduce<Dec>((acc, v) => acc.plus(money(v)), Dec('0')));
}

/** -1, 0 or 1. */
export function compareMoney(a: Money, b: Money): -1 | 0 | 1 {
  return money(a).cmp(money(b));
}

/**
 * amount x factor, rounded half-up: unit price x quantity, or x a decimal factor ("1.5").
 * A whole-number factor may be a JS integer (quantities are integers in the database).
 */
export function multiplyMoney(amount: Money, factor: string | number): Money {
  if (typeof factor === 'number' && !Number.isSafeInteger(factor)) {
    throw new RangeError(
      `A number factor must be a whole number, got ${factor}; pass decimals as strings`,
    );
  }
  const f = typeof factor === 'number' ? Dec(String(factor)) : decimal(factor, 'Factor');
  return toMoney(money(amount).times(f));
}

/**
 * amount / divisor, rounded half-up to `decimals` places and printed with exactly that many:
 * divideMoney("1000.00", 3, 5) -> "333.33333". For values that are not money, such as the ETA
 * unit price (5 decimals); a result that goes back into money maths is rounded with roundMoney.
 */
export function divideMoney(amount: Money, divisor: number, decimals: number): string {
  count(divisor, 'Divisor');
  if (!Number.isSafeInteger(decimals) || decimals < 0 || decimals > 10) {
    throw new RangeError(`Decimals must be a whole number from 0 to 10, got ${String(decimals)}`);
  }
  const result = money(amount).div(String(divisor)).round(decimals, Big.roundHalfUp);
  return result.eq('0') ? Dec('0').toFixed(decimals) : result.toFixed(decimals);
}

/** `percent`% of `amount`, rounded half-up. Percent is a string like "14" or "2.5" (0 to 100). */
export function percentOf(amount: Money, percentValue: string): Money {
  return toMoney(money(amount).times(percent(percentValue)).div('100'));
}

/**
 * Split `amount` in proportion to `weights` so the parts add back to `amount` EXACTLY
 * (largest remainder method, in piasters). Use it to spread a document discount across lines.
 * Leftover piasters go to the parts with the largest remainders; ties go to the earlier part.
 * Every part has the sign of `amount`. Weights are decimal strings >= 0 with a positive total.
 */
export function allocateMoney(amount: Money, weights: readonly string[]): Money[] {
  if (weights.length === 0) throw new RangeError('allocateMoney needs at least one weight');
  const ws = weights.map((w) => {
    const d = decimal(w, 'Weight');
    if (d.lt('0')) throw new RangeError(`Weight must be >= 0, got ${w}`);
    return d;
  });
  const total = ws.reduce<Dec>((acc, w) => acc.plus(w), Dec('0'));
  if (total.eq('0')) throw new RangeError('allocateMoney needs weights with a positive total');

  const a = money(amount);
  const negative = a.lt('0');
  const piasters = a.abs().times('100'); // whole number: money has at most 2 decimals

  // Exact integer floor and remainder of piasters * w / total (no rounding inside a division).
  const shares = ws.map((w, index) => {
    const numerator = piasters.times(w);
    let floor = numerator.div(total).round(0, Big.roundDown);
    if (floor.times(total).gt(numerator)) floor = floor.minus('1');
    return { index, floor, remainder: numerator.minus(floor.times(total)) };
  });

  const assigned = shares.reduce<Dec>((acc, s) => acc.plus(s.floor), Dec('0'));
  const leftover = Number(piasters.minus(assigned).toFixed(0)); // < weights.length
  const byRemainder = [...shares].sort((x, y) => y.remainder.cmp(x.remainder) || x.index - y.index);
  for (const s of byRemainder.slice(0, leftover)) s.floor = s.floor.plus('1');

  return shares.map((s) => {
    const part = s.floor.div('100');
    return toMoney(negative ? part.neg() : part);
  });
}

/** Split `amount` into `parts` equal parts that add back exactly: "1000.00" / 3 -> 333.34, 333.33, 333.33. */
export function splitMoney(amount: Money, parts: number): Money[] {
  return allocateMoney(
    amount,
    Array.from({ length: count(parts, 'Parts') }, () => '1'),
  );
}

/** One line's tax: `net + tax = gross` always holds exactly. */
export interface TaxBreakdown {
  net: Money;
  tax: Money;
  gross: Money;
}

/** Price WITHOUT VAT -> tax = round(net x rate%), gross = net + tax. */
export function taxFromNet(net: Money, ratePercent: string): TaxBreakdown {
  const n = money(net);
  const tax = toMoney(n.times(percent(ratePercent)).div('100'));
  return { net: toMoney(n), tax, gross: toMoney(n.plus(money(tax))) };
}

/** Price WITH VAT -> net = round(gross / (1 + rate%)), tax = gross - net (so they add back exactly). */
export function taxFromGross(gross: Money, ratePercent: string): TaxBreakdown {
  const g = money(gross);
  const net = toMoney(g.times('100').div(percent(ratePercent).plus('100')));
  return { net, tax: toMoney(g.minus(money(net))), gross: toMoney(g) };
}

/**
 * The line-level rule in one call: the line amount (after its discount) is either VAT-inclusive
 * or exclusive, per the shop's `prices_include_vat` setting snapshot on the document.
 */
export function taxForLine(
  lineAmount: Money,
  ratePercent: string,
  pricesIncludeVat: boolean,
): TaxBreakdown {
  return pricesIncludeVat
    ? taxFromGross(lineAmount, ratePercent)
    : taxFromNet(lineAmount, ratePercent);
}

/** Document totals = sums of the already rounded lines (never re-taxed at total level). */
export function sumTaxLines(lines: readonly TaxBreakdown[]): TaxBreakdown {
  return {
    net: sumMoney(lines.map((l) => l.net)),
    tax: sumMoney(lines.map((l) => l.tax)),
    gross: sumMoney(lines.map((l) => l.gross)),
  };
}

export type MoneyLanguage = 'ar' | 'en';

// Latin digits in both languages with the locale's separators; the currency goes after the amount
// (EcoFin-Web design.md section 4).
const MONEY_LOCALE: Record<MoneyLanguage, string> = { ar: 'ar-EG-u-nu-latn', en: 'en-US' };
export const EGP_LABEL: Record<MoneyLanguage, string> = { ar: 'ج.م', en: 'EGP' };

/** "1250.5" -> "1,250.50 EGP" / "1,250.50 ج.م". Rounded half-up to 2 decimals first; never via a float. */
export function formatEgp(value: string, lang: MoneyLanguage): string {
  const amount = new Intl.NumberFormat(MONEY_LOCALE[lang], {
    minimumFractionDigits: MONEY_DECIMALS,
    maximumFractionDigits: MONEY_DECIMALS,
  }).format(roundMoney(value) as Intl.StringNumericLiteral);
  return `${amount} ${EGP_LABEL[lang]}`;
}
