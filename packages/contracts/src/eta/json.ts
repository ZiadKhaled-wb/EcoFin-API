// contracts/src/eta/json.ts
//
// S08 (D10). Reads a receipt's JSON the way the ETA does: the text of every bare number is kept
// (10.50 stays 10.50, never 10.5), so the document can be serialized and hashed again from the
// exact bytes that were printed and will be sent. A real tokenizer, not a pattern: a ": 5," inside
// a product name is a string, not a number. Strings, numbers, objects and arrays only (a receipt
// has no true, false or null); anything else is refused.

import { dec, type EtaObject, type EtaValue } from './serialize.js';

export class EtaJsonError extends Error {
  constructor(message: string) {
    super(message);
    Object.setPrototypeOf(this, EtaJsonError.prototype);
    this.name = 'EtaJsonError';
  }
}

const NUMBER = /-?(?:0|[1-9]\d*)(?:\.\d+)?/y;
const WHITESPACE = /[ \t\n\r]*/y;

/** The document in `json`, numbers as EtaDecimal with their exact text. */
export function parseEtaJson(json: string): EtaValue {
  let at = 0;

  const fail = (what: string): never => {
    throw new EtaJsonError(`${what} at ${at}`);
  };
  const skip = () => {
    WHITESPACE.lastIndex = at;
    WHITESPACE.exec(json);
    at = WHITESPACE.lastIndex;
  };
  const expect = (char: string) => {
    skip();
    if (json[at] !== char) fail(`Expected ${char}`);
    at += 1;
  };

  const string = (): string => {
    expect('"');
    let out = '';
    for (;;) {
      const char = json[at];
      if (char === undefined) return fail('Unterminated string');
      at += 1;
      if (char === '"') return out;
      if (char !== '\\') {
        if (char < ' ') fail('Control character in a string');
        out += char;
        continue;
      }
      const escape = json[at];
      at += 1;
      switch (escape) {
        case '"':
        case '\\':
        case '/':
          out += escape;
          break;
        case 'b':
          out += '\b';
          break;
        case 'f':
          out += '\f';
          break;
        case 'n':
          out += '\n';
          break;
        case 'r':
          out += '\r';
          break;
        case 't':
          out += '\t';
          break;
        case 'u': {
          const hex = json.slice(at, at + 4);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) fail('Bad \\u escape');
          out += String.fromCharCode(Number.parseInt(hex, 16));
          at += 4;
          break;
        }
        default:
          fail('Bad escape');
      }
    }
  };

  const value = (): EtaValue => {
    skip();
    const char = json[at];
    if (char === '"') return string();
    if (char === '{') {
      at += 1;
      const out: Record<string, EtaValue> = {};
      skip();
      if (json[at] === '}') {
        at += 1;
        return out;
      }
      for (;;) {
        const key = string();
        if (Object.prototype.hasOwnProperty.call(out, key)) fail('Duplicate key');
        expect(':');
        out[key] = value();
        skip();
        if (json[at] === ',') {
          at += 1;
          continue;
        }
        expect('}');
        return out as EtaObject;
      }
    }
    if (char === '[') {
      at += 1;
      const out: EtaValue[] = [];
      skip();
      if (json[at] === ']') {
        at += 1;
        return out;
      }
      for (;;) {
        out.push(value());
        skip();
        if (json[at] === ',') {
          at += 1;
          continue;
        }
        expect(']');
        return out;
      }
    }
    NUMBER.lastIndex = at;
    const number = NUMBER.exec(json);
    if (!number) return fail('Unexpected value');
    at = NUMBER.lastIndex;
    if (json[at] === 'e' || json[at] === 'E') fail('Exponents are not used in receipts');
    return dec(number[0]);
  };

  const out = value();
  skip();
  if (at !== json.length) fail('Trailing text');
  return out;
}
