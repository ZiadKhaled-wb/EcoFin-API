import { describe, expect, it } from 'vitest';
import { qrPayload } from '@ziadkhaled-wb/contracts';

const UUID = '68e656b251e67e8358bef8483ab0d51c6619f3e7a1a9f0e75838d41ff368f320';

describe('ETA receipt QR text', () => {
  it('is the exact string for a known UUID, time, total and RIN', () => {
    expect(
      qrPayload({
        portalUrl: 'https://preprod.invoicing.eta.gov.eg',
        uuid: UUID,
        dateTimeIssued: '2026-10-12T09:15:02Z',
        totalAmount: '1026.00',
        rin: '674859545',
      }),
    ).toBe(
      `https://preprod.invoicing.eta.gov.eg/receipts/search/${UUID}/share/2026-10-12T09:15:02Z` +
        '#Total:1026.00,IssuerRIN:674859545',
    );
  });

  it("follows the SDK's template with the production portal", () => {
    // SDK example: http://invoicing.eta.gov.eg/receipts/search/<uuid>/share/2022-02-19T02:00Z#Total:1000.000,IssuerRIN:674859545
    expect(
      qrPayload({
        portalUrl: 'https://invoicing.eta.gov.eg/',
        uuid: UUID,
        dateTimeIssued: '2022-02-19T02:00Z',
        totalAmount: '1000.000',
        rin: '674859545',
      }),
    ).toBe(
      `https://invoicing.eta.gov.eg/receipts/search/${UUID}/share/2022-02-19T02:00Z#Total:1000.000,IssuerRIN:674859545`,
    );
  });
});
