import { describe, expect, it } from 'vitest';
import {
  addMoney,
  allocateMoney,
  compareMoney,
  formatEgp,
  multiplyMoney,
  percentOf,
  roundMoney,
  splitMoney,
  subtractMoney,
  sumMoney,
  sumTaxLines,
  taxForLine,
  taxFromGross,
  taxFromNet,
} from './index.js';

/** Deterministic pseudo-random amounts, so a failure is reproducible. */
function* amounts(count: number, seed = 42): Generator<string> {
  let s = seed;
  for (let i = 0; i < count; i++) {
    s = (s * 1103515245 + 12345) % 2147483648;
    const piasters = s % 10_000_000; // 0.00 .. 99,999.99
    yield `${Math.floor(piasters / 100)}.${String(piasters % 100).padStart(2, '0')}`;
  }
}

describe('roundMoney: one rule, half-up to 2 decimals', () => {
  it.each([
    ['2.345', '2.35'],
    ['2.344', '2.34'],
    ['-2.345', '-2.35'], // a half rounds away from zero
    ['0.005', '0.01'],
    ['-0.005', '-0.01'], // TEST-1 (EC-128)
    ['2.675', '2.68'], // TEST-1: as a float, 2.675 is 2.67499... and would round down
    ['1.995', '2.00'],
    ['12', '12.00'],
    ['12.5', '12.50'],
    ['-0.004', '0.00'], // never "-0.00"
    ['0.1000000000000000000001', '0.10'],
  ])('%s -> %s', (input, expected) => {
    expect(roundMoney(input)).toBe(expected);
  });

  it.each(['', ' 1', '1e3', '+1', '1,000', 'abc', '1.', '.5', 'NaN', 'Infinity'])(
    'rejects %j',
    (input) => {
      expect(() => roundMoney(input)).toThrow(RangeError);
    },
  );

  it('rejects JS numbers at runtime too', () => {
    // @ts-expect-error money is a string, a number is not accepted
    expect(() => roundMoney(0.1)).toThrow(RangeError);
  });

  it('throws when the result does not fit numeric(18,2)', () => {
    expect(() => roundMoney('99999999999999999')).toThrow(RangeError);
    expect(() => addMoney('9999999999999999.99', '0.01')).toThrow(RangeError);
  });
});

describe('add, subtract, sum, compare', () => {
  it('has no floating-point drift', () => {
    expect(addMoney('0.1', '0.2')).toBe('0.30');
    expect(sumMoney(Array.from({ length: 10 }, () => '0.10'))).toBe('1.00');
    expect(subtractMoney('1.00', '0.90')).toBe('0.10');
    expect(sumMoney([])).toBe('0.00');
  });

  it('only takes money (at most 2 decimals), so rounding never hides in a sum', () => {
    expect(() => addMoney('1.005', '1')).toThrow(RangeError);
    expect(() => sumMoney(['1', '0.001'])).toThrow(RangeError);
  });

  it('compares exactly', () => {
    expect(compareMoney('10.00', '9.99')).toBe(1);
    expect(compareMoney('10', '10.00')).toBe(0);
    expect(compareMoney('-1', '0')).toBe(-1);
  });
});

describe('multiplyMoney and percentOf', () => {
  it('unit price x quantity', () => {
    expect(multiplyMoney('19.99', 3)).toBe('59.97');
    expect(multiplyMoney('0.10', 0)).toBe('0.00');
    expect(multiplyMoney('10.00', '1.005')).toBe('10.05');
    expect(multiplyMoney('3.33', '0.5')).toBe('1.67'); // 1.665 -> half-up
  });

  it('refuses a fractional JS number factor', () => {
    expect(() => multiplyMoney('10.00', 1.5)).toThrow(RangeError);
  });

  it('percent of an amount, half-up', () => {
    expect(percentOf('1000.00', '14')).toBe('140.00');
    expect(percentOf('99.99', '14')).toBe('14.00'); // 13.9986
    expect(percentOf('0.05', '50')).toBe('0.03'); // 0.025
    expect(percentOf('200.00', '2.5')).toBe('5.00');
    expect(() => percentOf('1.00', '101')).toThrow(RangeError);
    expect(() => percentOf('1.00', '-1')).toThrow(RangeError);
  });
});

describe('splitMoney: parts add back exactly (Done when)', () => {
  it('1000 / 3', () => {
    const parts = splitMoney('1000.00', 3);
    expect(parts).toEqual(['333.34', '333.33', '333.33']);
    expect(sumMoney(parts)).toBe('1000.00');
  });

  it('100 / 3 and 0.01 / 3', () => {
    expect(splitMoney('100', 3)).toEqual(['33.34', '33.33', '33.33']);
    expect(splitMoney('0.01', 3)).toEqual(['0.01', '0.00', '0.00']);
  });

  it('negative amounts keep the sign on every part', () => {
    const parts = splitMoney('-1000.00', 3);
    expect(parts).toEqual(['-333.34', '-333.33', '-333.33']);
    expect(sumMoney(parts)).toBe('-1000.00');
  });

  it('1 part is the amount itself; 0 or fractional parts are refused', () => {
    expect(splitMoney('5.55', 1)).toEqual(['5.55']);
    expect(() => splitMoney('5.55', 0)).toThrow(RangeError);
    expect(() => splitMoney('5.55', 2.5)).toThrow(RangeError);
  });

  it('always sums exactly and parts differ by at most 0.01 (500 random cases)', () => {
    let n = 1;
    for (const amount of amounts(500)) {
      n = (n % 24) + 1; // 1..24 installments
      const parts = splitMoney(amount, n);
      expect(parts).toHaveLength(n);
      expect(sumMoney(parts)).toBe(roundMoney(amount));
      const sorted = [...parts].sort(compareMoney);
      expect(
        compareMoney(subtractMoney(sorted[n - 1] ?? '0', sorted[0] ?? '0'), '0.01'),
      ).toBeLessThan(1);
    }
  });
});

describe('allocateMoney: spread an amount over lines in proportion', () => {
  it('a 100.00 discount over lines of 300, 200 and 100', () => {
    const parts = allocateMoney('100.00', ['300.00', '200.00', '100.00']);
    expect(parts).toEqual(['50.00', '33.33', '16.67']);
    expect(sumMoney(parts)).toBe('100.00');
  });

  it('leftover piasters go to the largest remainders, ties to the earlier line', () => {
    expect(allocateMoney('0.02', ['1', '1', '1'])).toEqual(['0.01', '0.01', '0.00']);
    expect(allocateMoney('1.00', ['1', '2'])).toEqual(['0.33', '0.67']);
  });

  it('a zero weight gets nothing; bad weights are refused', () => {
    expect(allocateMoney('10.00', ['0', '5'])).toEqual(['0.00', '10.00']);
    expect(() => allocateMoney('10.00', [])).toThrow(RangeError);
    expect(() => allocateMoney('10.00', ['0', '0'])).toThrow(RangeError);
    expect(() => allocateMoney('10.00', ['-1', '2'])).toThrow(RangeError);
  });

  it('always sums exactly (500 random cases)', () => {
    const lines = [...amounts(4, 7)];
    for (const amount of amounts(500, 99)) {
      expect(sumMoney(allocateMoney(amount, lines))).toBe(roundMoney(amount));
    }
  });
});

describe('VAT: tax-inclusive <-> exclusive (Done when)', () => {
  it('exclusive price: 100.00 + 14% = 114.00', () => {
    expect(taxFromNet('100.00', '14')).toEqual({ net: '100.00', tax: '14.00', gross: '114.00' });
  });

  it('inclusive price: 114.00 at 14% = 100.00 + 14.00', () => {
    expect(taxFromGross('114.00', '14')).toEqual({ net: '100.00', tax: '14.00', gross: '114.00' });
  });

  it('inclusive price that does not divide evenly: 100.00 at 14%', () => {
    // 100 / 1.14 = 87.7192... -> 87.72; tax is what is left, so net + tax = gross exactly
    expect(taxFromGross('100.00', '14')).toEqual({ net: '87.72', tax: '12.28', gross: '100.00' });
  });

  it('half-up on the net of an inclusive price: 10.03 at 14%', () => {
    // 10.03 / 1.14 = 8.79824... -> 8.80
    expect(taxFromGross('10.03', '14')).toEqual({ net: '8.80', tax: '1.23', gross: '10.03' });
  });

  it('zero-rated and exempt lines carry no tax', () => {
    expect(taxFromNet('50.00', '0')).toEqual({ net: '50.00', tax: '0.00', gross: '50.00' });
    expect(taxFromGross('50.00', '0')).toEqual({ net: '50.00', tax: '0.00', gross: '50.00' });
  });

  it('net + tax = gross for every inclusive price, and exclusive -> inclusive round-trips (500 cases)', () => {
    for (const amount of amounts(500, 2026)) {
      const fromGross = taxFromGross(amount, '14');
      expect(addMoney(fromGross.net, fromGross.tax)).toBe(fromGross.gross);
      const fromNet = taxFromNet(amount, '14');
      expect(addMoney(fromNet.net, fromNet.tax)).toBe(fromNet.gross);
      expect(taxFromGross(fromNet.gross, '14')).toEqual(fromNet);
    }
  });

  it('refuses rates outside 0..100 and rates that are not decimal strings', () => {
    expect(() => taxFromNet('1.00', '100.01')).toThrow(RangeError);
    expect(() => taxFromGross('1.00', '-14')).toThrow(RangeError);
    expect(() => taxFromGross('1.00', '14%')).toThrow(RangeError);
  });
});

describe('line-level rounding is the rule (defined once)', () => {
  it('taxForLine follows the shop setting', () => {
    expect(taxForLine('114.00', '14', true)).toEqual(taxFromGross('114.00', '14'));
    expect(taxForLine('114.00', '14', false)).toEqual(taxFromNet('114.00', '14'));
  });

  it('document totals are sums of the rounded lines, not a total re-taxed', () => {
    // Three lines of 0.10 at 14%: each line's tax is 0.014 -> 0.01, so the document tax is 0.03.
    // Taxing the 0.30 total instead would give 0.042 -> 0.04. Line level wins.
    const lines = ['0.10', '0.10', '0.10'].map((amount) => taxForLine(amount, '14', false));
    expect(sumTaxLines(lines)).toEqual({ net: '0.30', tax: '0.03', gross: '0.33' });
    expect(percentOf('0.30', '14')).toBe('0.04');
  });

  it('an empty document totals zero', () => {
    expect(sumTaxLines([])).toEqual({ net: '0.00', tax: '0.00', gross: '0.00' });
  });

  it('TEST-1: 100.00 inclusive split in 3 lines at 14%: the lines add back to exactly 100.00', () => {
    const lines = splitMoney('100.00', 3).map((amount) => taxForLine(amount, '14', true));
    for (const line of lines) expect(addMoney(line.net, line.tax)).toBe(line.gross);
    const total = sumTaxLines(lines);
    expect(total.gross).toBe('100.00');
    expect(addMoney(total.net, total.tax)).toBe('100.00');
  });
});

describe('TEST-1: the helpers work in decimals, never JS numbers', () => {
  const MONEY = /^-?\d{1,16}\.\d{2}$/;
  const results: [string, unknown][] = [
    ['roundMoney', roundMoney('2.675')],
    ['addMoney', addMoney('0.1', '0.2')],
    ['subtractMoney', subtractMoney('1.00', '0.90')],
    ['sumMoney', sumMoney(['0.10', '0.20'])],
    ['multiplyMoney', multiplyMoney('19.99', '3')],
    ['percentOf', percentOf('100.00', '14')],
    ...splitMoney('1000', 3).map((p, i): [string, unknown] => [`splitMoney[${i}]`, p]),
    ...allocateMoney('100', ['1', '2']).map((p, i): [string, unknown] => [
      `allocateMoney[${i}]`,
      p,
    ]),
    ...Object.entries(taxFromNet('100', '14')).map(([k, v]): [string, unknown] => [
      `taxFromNet.${k}`,
      v,
    ]),
    ...Object.entries(taxFromGross('100', '14')).map(([k, v]): [string, unknown] => [
      `taxFromGross.${k}`,
      v,
    ]),
  ];

  it.each(results)('%s returns a 2-decimal string, not a number', (_name, value) => {
    expect(typeof value).toBe('string');
    expect(value).toMatch(MONEY);
  });

  it('every helper refuses a JS number for an amount', () => {
    const asMoney = 0.1 as unknown as string;
    expect(() => addMoney(asMoney, '0.20')).toThrow(RangeError);
    expect(() => subtractMoney('1.00', asMoney)).toThrow(RangeError);
    expect(() => sumMoney([asMoney])).toThrow(RangeError);
    expect(() => multiplyMoney(asMoney, '2')).toThrow(RangeError);
    expect(() => percentOf(asMoney, '14')).toThrow(RangeError);
    expect(() => splitMoney(asMoney, 3)).toThrow(RangeError);
    expect(() => allocateMoney(asMoney, ['1'])).toThrow(RangeError);
    expect(() => taxFromNet(asMoney, '14')).toThrow(RangeError);
    expect(() => taxFromGross(asMoney, '14')).toThrow(RangeError);
  });
});

describe('formatEgp: EGP in Arabic and English', () => {
  it('English: grouping, 2 decimals, currency after', () => {
    expect(formatEgp('1250', 'en')).toBe('1,250.00 EGP');
    expect(formatEgp('-1234567.5', 'en')).toBe('-1,234,567.50 EGP');
  });

  it('Arabic: Latin digits, currency after', () => {
    expect(formatEgp('1250.5', 'ar')).toBe('1,250.50 ج.م');
  });

  it('rounds half-up exactly before formatting (no float)', () => {
    expect(formatEgp('2.345', 'en')).toBe('2.35 EGP');
    expect(formatEgp('1.005', 'en')).toBe('1.01 EGP'); // as a float, 1.005 would print 1.00
    expect(formatEgp('9999999999999999.99', 'en')).toBe('9,999,999,999,999,999.99 EGP');
    expect(formatEgp('-0.004', 'en')).toBe('0.00 EGP');
  });
});
