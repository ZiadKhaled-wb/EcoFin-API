// server/src/eta/build-return.ts
//
// T02 (D67, decision 14). A Return Receipt v1.2 (docs/eta/ERECEIPT_SPEC.md, section 12): the
// receipt structure with type `r` and header.referenceUUID naming the sale receipt, which is
// part of the return's UUID. The ETA takes a return up to 540 days after the sale receipt.
// Not wired to anything yet: S05 (returns) calls it with its own stored lines.

import {
  buildDocument,
  RECEIPT_TYPE_RETURN,
  type Receipt,
  type ReceiptSource,
  type SourceLine,
} from './build-receipt';
import { UUID_PATTERN } from './uuid';

export const RETURN_WINDOW_DAYS = 540;

/** The sale receipt the goods were sold on. */
export interface ReturnOriginal {
  /** Its ETA UUID. */
  uuid: string;
  /** When it was issued (UTC). */
  issued_at: string;
}

/** The return document as stored, and the POS chain it joins. */
export interface ReturnContext extends Omit<ReceiptSource, 'sale' | 'lines'> {
  return: {
    number: string;
    /** UTC, whole seconds. */
    issued_at: string;
    prices_include_vat: boolean;
    total: string;
  };
  /** The UUID of the POS's previous receipt, "" for its first. */
  previous_uuid: string;
}

export class ReturnTooLateError extends Error {
  readonly code = 'RETURN_TOO_LATE';

  constructor(days: number) {
    super(
      `The sale receipt is ${days} days old: the ETA takes a return for ${RETURN_WINDOW_DAYS} days`,
    );
    Object.setPrototypeOf(this, ReturnTooLateError.prototype);
    this.name = 'ReturnTooLateError';
  }
}

/**
 * The return receipt for `returnLines` (the return's own stored lines: quantities and amounts
 * of what comes back) against the sale receipt `original`.
 */
export function buildReturnReceipt(
  original: ReturnOriginal,
  returnLines: readonly SourceLine[],
  context: ReturnContext,
): Receipt {
  if (!UUID_PATTERN.test(original.uuid)) {
    throw new RangeError('A return needs the UUID of the sale receipt');
  }
  const sold = Date.parse(original.issued_at);
  const returned = Date.parse(context.return.issued_at);
  if (Number.isNaN(sold) || Number.isNaN(returned) || returned < sold) {
    throw new RangeError('A return is issued after its sale receipt');
  }
  const days = Math.floor((returned - sold) / 86_400_000);
  if (days > RETURN_WINDOW_DAYS) throw new ReturnTooLateError(days);

  return buildDocument(
    RECEIPT_TYPE_RETURN,
    {
      sale: context.return,
      lines: returnLines,
      payments: context.payments,
      customer: context.customer,
      seller: context.seller,
      device: context.device,
    },
    context.previous_uuid,
    original.uuid,
  );
}
