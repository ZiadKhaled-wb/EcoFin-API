// contracts/src/eta/qr.ts (moved from server/src/eta by S08, D7: the POS prints the same QR text).
//
// T02 (D67). The text of the receipt's QR code (docs/eta/ERECEIPT_SPEC.md, section 14): a link to
// the receipt on the ETA portal of the shop's environment. S04 prints it as a QR image.

export interface QrInput {
  /** The invoicing portal of the receipt's environment, without a trailing slash. */
  portalUrl: string;
  uuid: string;
  /** header.dateTimeIssued, as it is in the receipt. */
  dateTimeIssued: string;
  /** totalAmount, as it is in the receipt. */
  totalAmount: string;
  rin: string;
}

/** `{portal}/receipts/search/{uuid}/share/{dateTimeIssued}#Total:{total},IssuerRIN:{rin}` */
export function qrPayload(input: QrInput): string {
  const portal = input.portalUrl.replace(/\/+$/, '');
  return (
    `${portal}/receipts/search/${input.uuid}/share/${input.dateTimeIssued}` +
    `#Total:${input.totalAmount},IssuerRIN:${input.rin}`
  );
}
