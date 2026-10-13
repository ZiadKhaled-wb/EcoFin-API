// server/src/eta/serialize.ts
//
// T02 (D67). The ETA's "document serialization approach" (docs/eta/ERECEIPT_SPEC.md, section 8):
// the text a receipt's UUID is the SHA-256 of. The ETA serializes every value exactly as it is
// written in the JSON it receives (10.50 stays "10.50"), so a document here never holds a JS
// number: a decimal is an EtaDecimal carrying its text, and toJson() writes that same text as a
// bare JSON number. What is hashed and what is sent can't differ.

/** A decimal written in the JSON as a bare number with exactly this text. */
export class EtaDecimal {
  readonly text: string;

  constructor(text: string) {
    if (typeof text !== 'string' || !/^-?\d+(\.\d+)?$/.test(text)) {
      throw new RangeError(`Not a decimal: ${String(text)}`);
    }
    this.text = text;
  }
}

export const dec = (text: string): EtaDecimal => new EtaDecimal(text);

/** Properties are serialized in the order they were added. An undefined property is absent. */
export type EtaValue = string | EtaDecimal | readonly EtaValue[] | EtaObject;
export interface EtaObject {
  readonly [key: string]: EtaValue | undefined;
}

const isArray = (value: EtaValue): value is readonly EtaValue[] => Array.isArray(value);

/**
 * The SDK's algorithm: a property name in upper case and double quotes, then its value; a simple
 * value in double quotes; an array's name once for the array and again before every element;
 * everything joined with nothing between.
 */
export function serialize(value: EtaValue): string {
  if (typeof value === 'string') return `"${value}"`;
  if (value instanceof EtaDecimal) return `"${value.text}"`;
  if (isArray(value)) throw new TypeError('An array is serialized under its property name');
  let out = '';
  for (const [key, child] of Object.entries(value)) {
    if (child === undefined) continue;
    const name = `"${key.toUpperCase()}"`;
    if (isArray(child)) {
      out += name;
      for (const element of child) out += name + serialize(element);
    } else {
      out += name + serialize(child);
    }
  }
  return out;
}

/** The document as compact JSON: strings escaped as JSON, decimals as their own text. */
export function toJson(value: EtaValue): string {
  if (typeof value === 'string') return JSON.stringify(value);
  if (value instanceof EtaDecimal) return value.text;
  if (isArray(value)) return `[${value.map(toJson).join(',')}]`;
  const parts: string[] = [];
  for (const [key, child] of Object.entries(value)) {
    if (child !== undefined) parts.push(`${JSON.stringify(key)}:${toJson(child)}`);
  }
  return `{${parts.join(',')}}`;
}

/**
 * Text that is the same in the serialized form and in JSON: no double quote, backslash or
 * control character (a quote is the one place where the SDK's two forms could differ), trimmed,
 * runs of white space made one space, cut to the field's limit.
 */
export function cleanText(value: string | null | undefined, max: number): string {
  return (value ?? '')
    .replace(/["“”]/g, "'")
    .replace(/\\/g, '/')
    .replace(/\p{Cc}/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, max)
    .trim();
}
