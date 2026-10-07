import { describe, expect, it } from 'vitest';
import { ShopProfile, ShopProfileUpdateBody } from './profile.js';
import { ShopSettingsUpdateBody } from './settings.js';

describe('P04 shop profile contracts', () => {
  it('accepts the V1 in-house profile and optional owner-entered legal status', () => {
    expect(
      ShopProfile.parse({
        legal_name: null,
        commercial_register: null,
        tax_registration_no: null,
        consumer_finance_legal_status: 'Owner supplied status',
        creditor_model: 'in_house',
        installments_enabled: true,
        updated_at: '2026-10-07T00:00:00.000Z',
      }).creditor_model,
    ).toBe('in_house');
  });

  it('rejects unsupported models, oversized legal notes, and profile keys in P03 settings', () => {
    expect(ShopProfile.safeParse({ creditor_model: 'third_party' }).success).toBe(false);
    expect(
      ShopProfileUpdateBody.safeParse({ consumer_finance_legal_status: 'x'.repeat(501) }).success,
    ).toBe(false);
    expect(ShopSettingsUpdateBody.safeParse({ tax_registration_no: '123' }).success).toBe(false);
  });
});
