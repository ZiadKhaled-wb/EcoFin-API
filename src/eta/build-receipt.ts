// server/src/eta/build-receipt.ts
//
// T02 (D67). The receipt builder itself moved to contracts (S08, D7: the offline POS builds the
// same receipt); it returns the receipt with header.uuid empty. This module fills the UUID with
// Node's crypto, so the server's callers (prepare, correct, the return builder) are unchanged.

import {
  buildDocumentBody,
  buildReceiptBody,
  RECEIPT_TYPE_RETURN,
  RECEIPT_TYPE_SALE,
  type Receipt,
  type ReceiptSource,
} from '@ziadkhaled-wb/contracts';
import { withUuid } from './uuid';

export {
  BUYER_ID_THRESHOLD,
  paymentMethodCode,
  RECEIPT_TYPE_RETURN,
  RECEIPT_TYPE_SALE,
  RECEIPT_TYPE_VERSION,
  ReceiptBlockedError,
  type BlockCode,
  type Receipt,
  type ReceiptBuyer,
  type ReceiptDiscount,
  type ReceiptHeader,
  type ReceiptItem,
  type ReceiptSeller,
  type ReceiptSource,
  type SourceLine,
  type TaxableItem,
  type TaxTotal,
} from '@ziadkhaled-wb/contracts';

/**
 * The receipt or return receipt of a stored document, with its UUID.
 * `previousUuid`: the UUID of the POS's previous receipt, "" for its first.
 * `referenceUuid`: a return's sale receipt.
 * `referenceOldUuid`: the rejected receipt this one corrects (T03), "" for a first submission.
 */
export function buildDocument(
  receiptType: typeof RECEIPT_TYPE_SALE | typeof RECEIPT_TYPE_RETURN,
  source: ReceiptSource,
  previousUuid: string,
  referenceUuid?: string,
  referenceOldUuid = '',
): Receipt {
  return withUuid(
    buildDocumentBody(receiptType, source, previousUuid, referenceUuid, referenceOldUuid),
  );
}

/** A sale's Receipt v1.2 (type `s`), with its UUID. */
export function buildReceipt(
  source: ReceiptSource,
  previousUuid: string,
  referenceOldUuid = '',
): Receipt {
  return withUuid(buildReceiptBody(source, previousUuid, referenceOldUuid));
}
