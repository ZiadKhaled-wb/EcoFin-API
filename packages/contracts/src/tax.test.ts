import { readFileSync } from 'node:fs';
import { describe, it, expect } from 'vitest';
import {
  TaxClassCreateBody,
  TaxClassUpdateBody,
  TaxInputError,
  computeDocumentTax,
  returnLineTax,
  type TaxDocumentInput,
} from './tax';
import { addMoney } from './money';

// The golden cases both engines run (the SQL test embeds the same JSON).
const golden = JSON.parse(
  readFileSync(
    new URL('../../../supabase/tests/fixtures/t01_tax_cases.json', import.meta.url),
    'utf8',
  ),
) as {
  documents: { id: string; input: TaxDocumentInput; expected: unknown }[];
  returns: {
    id: string;
    original: { quantity: number; net: string; tax: string; gross: string };
    expected: { quantity: number; net: string; tax: string; gross: string }[];
  }[];
};

describe('T01 VAT engine (TypeScript)', () => {
  it.each(golden.documents.map((c) => [c.id, c] as const))('golden %s', (_id, c) => {
    expect(computeDocumentTax(c.input)).toEqual(c.expected);
  });

  it.each(golden.returns.map((c) => [c.id, c] as const))('golden %s', (_id, c) => {
    let prev = { quantity: 0, net: '0.00', tax: '0.00', gross: '0.00' };
    for (const step of c.expected) {
      const got = returnLineTax(c.original, prev, step.quantity);
      expect({ quantity: step.quantity, ...got }).toEqual(step);
      prev = {
        quantity: prev.quantity + step.quantity,
        net: addMoney(prev.net, got.net),
        tax: addMoney(prev.tax, got.tax),
        gross: addMoney(prev.gross, got.gross),
      };
    }
  });

  it('every line adds up: net + tax = gross, and totals are sums of the lines', () => {
    for (const c of golden.documents) {
      const r = computeDocumentTax(c.input);
      for (const l of r.lines)
        expect(Number(l.net) * 100 + Number(l.tax) * 100).toBeCloseTo(Number(l.gross) * 100, 6);
      const inc = c.input.prices_include_vat;
      expect(Number(r.total) * 100).toBeCloseTo(
        (Number(r.subtotal) - Number(r.discount_total) + (inc ? 0 : Number(r.tax_total))) * 100,
        6,
      );
    }
  });

  it('refuses discounts larger than the amount', () => {
    const line = { unit_price: '10.00', quantity: 1, tax_rate: '14' };
    expect(() =>
      computeDocumentTax({ prices_include_vat: false, document_discount: '10.01', lines: [line] }),
    ).toThrow(TaxInputError);
    expect(() =>
      computeDocumentTax({
        prices_include_vat: false,
        lines: [{ ...line, line_discount: '11.00' }],
      }),
    ).toThrow(TaxInputError);
    expect(() =>
      returnLineTax(
        { quantity: 2, net: '2.00', tax: '0.28', gross: '2.28' },
        { quantity: 1, net: '1.00', tax: '0.14', gross: '1.14' },
        2,
      ),
    ).toThrow(RangeError);
  });

  it('keeps zero-rated and exempt classes at 0%', () => {
    const base = { name: 'Zero', eta_tax_type: 'T1', eta_subtype: 'V001' };
    expect(TaxClassCreateBody.safeParse({ ...base, kind: 'zero', rate: '0' }).success).toBe(true);
    expect(TaxClassCreateBody.safeParse({ ...base, kind: 'zero', rate: '5' }).success).toBe(false);
    expect(TaxClassUpdateBody.safeParse({ rate: '15' }).success).toBe(true);
    expect(TaxClassUpdateBody.safeParse({}).success).toBe(false);
  });
});
