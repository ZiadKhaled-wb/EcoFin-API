// src/test/eta-json.ts
//
// T02 test helper: reads JSON the way the ETA does, keeping the text of every bare number (10.50
// is not 10.5), so a document can be serialized and hashed from the bytes that were sent. Used by
// the serialization golden test and by the fake ETA. Production code never parses a receipt.

import { dec, type EtaValue } from '@ziadkhaled-wb/contracts';

export function parseExactJson(json: string): EtaValue {
  const tagged = json.replace(/(:\s*)(-?\d+(?:\.\d+)?)(?=\s*[,}\]])/g, '$1{"$dec":"$2"}');
  const convert = (value: unknown): EtaValue => {
    if (typeof value === 'string') return value;
    if (Array.isArray(value)) return value.map(convert);
    if (typeof value === 'object' && value !== null) {
      const entries = Object.entries(value);
      const [first] = entries;
      if (entries.length === 1 && first?.[0] === '$dec' && typeof first[1] === 'string') {
        return dec(first[1]);
      }
      return Object.fromEntries(entries.map(([key, child]) => [key, convert(child)]));
    }
    throw new TypeError(`Unexpected value in the JSON: ${String(value)}`);
  };
  return convert(JSON.parse(tagged));
}
