import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { parseExactJson } from '../test/eta-json';
import { cleanText, dec, EtaDecimal, serialize, toJson } from '@ziadkhaled-wb/contracts';

// The SDK's JSON read the way the ETA reads it: every bare number keeps its text.
const parseExact = parseExactJson;

const fixture = (name: string) =>
  readFileSync(new URL(`fixtures/${name}`, import.meta.url), 'utf8');

describe('ETA serialization (SDK "document serialization approach")', () => {
  it("golden: the SDK's own example document gives the SDK's own serialized text", () => {
    // https://sdk.invoicing.eta.gov.eg/files/one-doc.json -> one-doc-serialized.json.txt
    const document = parseExact(fixture('sdk-one-doc.json'));
    const expected = fixture('sdk-one-doc-serialized.txt');
    expect(expected.startsWith('"ISSUER""ADDRESS""BRANCHID""1""COUNTRY""EG"')).toBe(true);
    expect(serialize(document)).toBe(expected);
  });

  it('golden: an array name is written once for the array and again before each element', () => {
    const expected = fixture('sdk-one-doc-serialized.txt');
    expect(expected).toContain(
      '"TAXABLEITEMS""TAXABLEITEMS""TAXTYPE""T1""AMOUNT""272.07""SUBTYPE""T1""RATE""14.00""TAXABLEITEMS""TAXTYPE""T2"',
    );
    expect(serialize({ taxTotals: [{ taxType: 'T1' }, { taxType: 'T4' }] })).toBe(
      '"TAXTOTALS""TAXTOTALS""TAXTYPE""T1""TAXTOTALS""TAXTYPE""T4"',
    );
  });

  it('a nested object: names in upper case, in the order they were written', () => {
    expect(
      serialize({
        seller: { rin: '674859545', branchAddress: { country: 'EG', street: '16 st' } },
      }),
    ).toBe('"SELLER""RIN""674859545""BRANCHADDRESS""COUNTRY""EG""STREET""16 st"');
    expect(serialize({ b: '1', a: '2' })).toBe('"B""1""A""2"');
  });

  it('an array of objects, an empty array and an array of simple values', () => {
    expect(
      serialize({
        itemData: [
          { internalCode: 'A', quantity: dec('2') },
          { internalCode: 'B', quantity: dec('1') },
        ],
      }),
    ).toBe(
      '"ITEMDATA""ITEMDATA""INTERNALCODE""A""QUANTITY""2""ITEMDATA""INTERNALCODE""B""QUANTITY""1"',
    );
    expect(serialize({ signatures: [] })).toBe('"SIGNATURES"');
    expect(serialize({ codes: ['x', 'y'] })).toBe('"CODES""CODES""x""CODES""y"');
  });

  it('empty strings are kept as "" and an absent property is left out', () => {
    expect(serialize({ uuid: '', previousUUID: '', referenceOldUUID: '' })).toBe(
      '"UUID""""PREVIOUSUUID""""REFERENCEOLDUUID"""',
    );
    expect(serialize({ type: 'P', id: undefined, name: undefined })).toBe('"TYPE""P"');
  });

  it('a decimal keeps exactly the text it was given', () => {
    expect(serialize({ a: dec('10.50'), b: dec('0'), c: dec('1000.00000'), d: dec('-5.0') })).toBe(
      '"A""10.50""B""0""C""1000.00000""D""-5.0"',
    );
    for (const bad of ['1e3', '1,5', ' 1', '', '1.', '.5', 'abc']) {
      expect(() => dec(bad)).toThrow(RangeError);
    }
    expect(() => new EtaDecimal(10 as unknown as string)).toThrow(RangeError);
  });

  it('the document root is an object, not an array', () => {
    expect(() => serialize([{ a: '1' }])).toThrow(TypeError);
  });

  it('toJson writes decimals as bare numbers with the same text, and valid JSON', () => {
    const document = {
      header: { uuid: '', currency: 'EGP', exchangeRate: dec('0') },
      itemData: [
        { description: 'تلفزيون 55', unitPrice: dec('1000.00000'), total: dec('1026.00') },
      ],
      buyer: { type: 'P', id: undefined },
    };
    const json = toJson(document);
    expect(json).toBe(
      '{"header":{"uuid":"","currency":"EGP","exchangeRate":0},' +
        '"itemData":[{"description":"تلفزيون 55","unitPrice":1000.00000,"total":1026.00}],' +
        '"buyer":{"type":"P"}}',
    );
    expect(JSON.parse(json)).toEqual({
      header: { uuid: '', currency: 'EGP', exchangeRate: 0 },
      itemData: [{ description: 'تلفزيون 55', unitPrice: 1000, total: 1026 }],
      buyer: { type: 'P' },
    });
    // What is hashed is what is sent: the JSON read back the ETA's way serializes the same.
    expect(serialize(parseExact(json))).toBe(serialize(document));
  });

  it("toJson of the SDK's example reads back to the same serialized text", () => {
    const document = parseExact(fixture('sdk-one-doc.json'));
    expect(serialize(parseExact(toJson(document)))).toBe(fixture('sdk-one-doc-serialized.txt'));
  });

  it('cleanText: no quote, backslash or control character; trimmed and cut', () => {
    expect(cleanText('  Sofa "Lux"\t3\\2 \n seats ', 100)).toBe("Sofa 'Lux' 3/2 seats");
    expect(cleanText('abcdef', 3)).toBe('abc');
    expect(cleanText('ab   cd', 3)).toBe('ab');
    expect(cleanText(null, 10)).toBe('');
    expect(cleanText('كنبة «مودرن»', 50)).toBe('كنبة «مودرن»');
    // A cleaned text is the same in the serialized form and in the JSON.
    const text = cleanText('A "quoted" \\ name', 50);
    expect(toJson({ name: text })).toBe(`{"name":"${text}"}`);
  });
});
