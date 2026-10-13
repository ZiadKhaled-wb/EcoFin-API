// server/src/eta/signer.ts
//
// T02 (D67, decision 11). The ETA's submit call has a `signatures` field (CAdES-BES over the
// SHA-256 of the serialized batch), but the SDK says its validation is not deployed. Until
// pre-production refuses an unsigned submission, nothing is signed: this is the place where a
// real signer goes (docs/eta/ERECEIPT_SPEC.md, section 3).

export interface EtaSignature {
  /** I = issuer, S = service provider. */
  signatureType: 'I' | 'S';
  /** Base64 CAdES-BES. */
  value: string;
}

export interface ReceiptSigner {
  /** `receiptsJson`: the JSON text of each receipt of the batch, in order, exactly as sent. */
  sign(receiptsJson: readonly string[]): Promise<EtaSignature[]>;
}

/** Signs nothing: the submission carries an empty `signatures` list. */
export const noSignature: ReceiptSigner = {
  sign: () => Promise.resolve([]),
};
