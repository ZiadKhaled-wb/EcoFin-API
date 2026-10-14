// server/src/eta/correct.ts
//
// T03 (EC-91). The correction of a rejected receipt (docs/eta/ERECEIPT_SPEC.md, "Corrections"):
//   - the receipt is built again from the unchanged sale and the current master data;
//   - it keeps the rejected receipt's previousUUID, carries referenceOldUUID = the rejected UUID
//     and gets a new UUID (the SDK rule);
//   - when nothing but those three header fields differs from the stored receipt, the data was not
//     fixed: nothing is stored or sent.

import { buildReceipt, type Receipt, type ReceiptSource } from './build-receipt';
import { UUID_PATTERN } from './uuid';

/** The corrected receipt of a rejected one. Throws ReceiptBlockedError when data is still missing. */
export function buildCorrection(
  source: ReceiptSource,
  previousUuid: string,
  rejectedUuid: string,
): Receipt {
  if (!UUID_PATTERN.test(rejectedUuid)) throw new RangeError('rejectedUuid must be a receipt UUID');
  const receipt = buildReceipt(source, previousUuid, rejectedUuid);
  if (receipt.header.uuid === rejectedUuid) {
    throw new RangeError('A correction must have a new UUID');
  }
  return receipt;
}

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

function isObject(value: Json | undefined): value is { [key: string]: Json } {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** The receipt without the three header fields a correction changes. */
function stripChain(text: string): Json | undefined {
  try {
    const parsed = JSON.parse(text) as Json;
    const header = isObject(parsed) ? parsed['header'] : undefined;
    if (isObject(parsed) && isObject(header)) {
      const rest = { ...header };
      delete rest['uuid'];
      delete rest['previousUUID'];
      delete rest['referenceOldUUID'];
      return { ...parsed, header: rest };
    }
    return parsed;
  } catch {
    return undefined;
  }
}

function same(a: Json | undefined, b: Json | undefined): boolean {
  if (a === b) return true;
  if (Array.isArray(a) && Array.isArray(b)) {
    return a.length === b.length && a.every((value, index) => same(value, b[index]));
  }
  if (isObject(a) && isObject(b)) {
    const keys = Object.keys(a);
    return (
      keys.length === Object.keys(b).length &&
      keys.every((key) => Object.hasOwn(b, key) && same(a[key], b[key]))
    );
  }
  return false;
}

/**
 * True when the two receipt texts are the same receipt apart from `header.uuid`,
 * `header.previousUUID` and `header.referenceOldUUID` (both parsed as JSON and deep-compared).
 * Text that is not JSON is never "the same".
 */
export function sameReceiptIgnoringChain(stored: string, rebuilt: string): boolean {
  const a = stripChain(stored);
  const b = stripChain(rebuilt);
  return a !== undefined && b !== undefined && same(a, b);
}

/** A correction note starts the stored error; the ETA's own text follows. */
const NOTE_PREFIX = /^CORRECTION_[A-Z_]+(?::[A-Z_]+)?: /;

/** The ETA's error without any correction note in front of it. */
export function originalEtaError(lastError: string | null): string {
  let text = lastError ?? '';
  while (NOTE_PREFIX.test(text)) text = text.replace(NOTE_PREFIX, '');
  return text;
}

/** `CODE: <the ETA's error>`, as it is stored while the receipt stays rejected. */
export function correctionNote(code: string, lastError: string | null): string {
  return `${code}: ${originalEtaError(lastError)}`.slice(0, 2000);
}

export interface ParsedEtaError {
  message: string;
  propertyPath: string | null;
  details: string[];
  /** The last correction found the data unchanged. */
  nothingChanged: boolean;
}

const KIND_PREFIX = /^[A-Z][A-Z_]+(?::[A-Z_]+)?: /;
/** An optional code (`CV307`), an optional property path (`itemData[0].itemCode`), then the text. */
const LINE =
  /^(?:([A-Z]{1,4}\d{1,5})\s+)?(?:([A-Za-z_]\w*(?:\[\d+\])?(?:\.[A-Za-z_]\w*(?:\[\d+\])?)+|[A-Za-z_]\w*\[\d+\]):?\s+)?([\s\S]+)$/;

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null;
}

function fromObject(value: Record<string, unknown>): Omit<ParsedEtaError, 'nothingChanged'> {
  const nested = Array.isArray(value['details']) ? (value['details'] as unknown[]) : [];
  const details = nested
    .map((d) =>
      typeof d === 'object' && d !== null
        ? text((d as Record<string, unknown>)['message'])
        : text(d),
    )
    .filter((d): d is string => d !== null);
  return {
    message: text(value['message']) ?? text(value['error']) ?? '',
    propertyPath: text(value['propertyPath']),
    details,
  };
}

/**
 * The stored `last_error` as a message, a property path and details. It handles the ETA's error
 * written as JSON (`{ message, propertyPath, details: [{ message }] }`), the masked one-line text
 * T02 stores (`ETA_INVALID: CV307 itemData[0].itemCode: bad; more`), a plain string, and junk
 * (anything else gives an empty message and no path). Never throws.
 */
export function parseEtaError(lastError: unknown): ParsedEtaError {
  if (typeof lastError !== 'string') {
    return { message: '', propertyPath: null, details: [], nothingChanged: false };
  }
  const nothingChanged = /^CORRECTION_NOTHING_CHANGED: /.test(lastError);
  let body = originalEtaError(lastError);
  while (KIND_PREFIX.test(body)) body = body.replace(KIND_PREFIX, '');
  body = body.trim().slice(0, 2000);

  if (body.startsWith('{')) {
    try {
      const parsed = JSON.parse(body) as unknown;
      if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
        return { ...fromObject(parsed as Record<string, unknown>), nothingChanged };
      }
    } catch {
      /* not JSON after all: read it as text */
    }
  }
  const [head = '', ...rest] = body.split(/;\s+/);
  const match = LINE.exec(head.trim());
  const message = match?.[3]?.trim() ?? head.trim();
  const details = rest.map((part) => part.trim()).filter((part) => part !== '');
  return { message, propertyPath: match?.[2] ?? null, details, nothingChanged };
}
