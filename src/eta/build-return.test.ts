import { describe, expect, it } from 'vitest';
import { buildReceipt, type ReceiptSource, type SourceLine } from './build-receipt';
import { buildReturnReceipt, ReturnTooLateError, type ReturnContext } from './build-return';
import { serialize } from '@ziadkhaled-wb/contracts';
import { receiptUuid } from './uuid';

const line: SourceLine = {
  line_no: 1,
  quantity: 1,
  unit_price: '1140.00',
  discount_amount: '0.00',
  tax_rate: '14.00',
  tax_amount: '140.00',
  line_total: '1140.00',
  sku: 'TV-55',
  name: 'TV 55',
  eta_item_code: 'EG-674859545-TV55',
  eta_item_type: 'EGS',
  eta_tax_type: 'T1',
  eta_subtype: 'V009',
};

const sale: ReceiptSource = {
  sale: {
    number: 'MAIN-SL-26-000001',
    issued_at: '2026-01-01T10:00:00Z',
    prices_include_vat: true,
    total: '1140.00',
  },
  lines: [line],
  payments: [{ method: 'cash', amount: '1140.00' }],
  customer: null,
  seller: {
    rin: '674859545',
    name: 'Al Nour',
    activity_code: '4753',
    branch_code: '0',
    governorate: 'Cairo',
    city: 'Nasr City',
    street: '16 Abbas El Akkad',
    building_number: '14',
  },
  device: { serial: 'POS-001', status: 'active', is_active: true },
};

const context = (issuedAt: string, previousUuid: string): ReturnContext => ({
  return: {
    number: 'MAIN-RT-26-000001',
    issued_at: issuedAt,
    prices_include_vat: true,
    total: '1140.00',
  },
  payments: sale.payments,
  customer: sale.customer,
  seller: sale.seller,
  device: sale.device,
  previous_uuid: previousUuid,
});

describe('ETA return receipt builder', () => {
  const original = buildReceipt(sale, '');
  const of = { uuid: original.header.uuid, issued_at: sale.sale.issued_at };

  it('is type r and refers to the UUID of the sale receipt', () => {
    const returned = buildReturnReceipt(
      of,
      [line],
      context('2026-01-05T12:00:00Z', original.header.uuid),
    );
    expect(returned.documentType).toEqual({ receiptType: 'r', typeVersion: '1.2' });
    expect(returned.header.referenceUUID).toBe(original.header.uuid);
    // After previousUUID and before referenceOldUUID, as the Return Receipt v1.2 page lists it.
    expect(Object.keys(returned.header)).toEqual([
      'dateTimeIssued',
      'receiptNumber',
      'uuid',
      'previousUUID',
      'referenceUUID',
      'referenceOldUUID',
      'currency',
      'exchangeRate',
    ]);
    expect(returned.header.previousUUID).toBe(original.header.uuid);
    expect(returned.header.receiptNumber).toBe('MAIN-RT-26-000001');
    expect(returned.totalAmount.text).toBe('1140.00');
  });

  it('the reference is part of the UUID', () => {
    const returned = buildReturnReceipt(of, [line], context('2026-01-05T12:00:00Z', ''));
    expect(returned.header.uuid).toBe(receiptUuid(returned));
    expect(serialize(returned)).toContain(`"REFERENCEUUID""${original.header.uuid}"`);
    const other = buildReturnReceipt(
      { ...of, uuid: 'b'.repeat(64) },
      [line],
      context('2026-01-05T12:00:00Z', ''),
    );
    expect(other.header.uuid).not.toBe(returned.header.uuid);
  });

  it('a partial return carries the lines and total of what came back', () => {
    const half: SourceLine = {
      ...line,
      tax_amount: '70.00',
      line_total: '570.00',
      unit_price: '570.00',
    };
    const ctx = context('2026-01-05T12:00:00Z', '');
    const returned = buildReturnReceipt(of, [half], {
      ...ctx,
      return: { ...ctx.return, total: '570.00' },
    });
    expect(returned.totalAmount.text).toBe('570.00');
    expect(returned.itemData[0]?.netSale.text).toBe('500.00');
  });

  it('is accepted up to 540 days after the sale receipt and refused after', () => {
    // 2026-01-01T10:00:00Z + 540 days = 2027-06-25T10:00:00Z
    expect(() => buildReturnReceipt(of, [line], context('2027-06-25T10:00:00Z', ''))).not.toThrow();
    expect(() => buildReturnReceipt(of, [line], context('2027-06-26T09:59:59Z', ''))).not.toThrow();
    expect(() => buildReturnReceipt(of, [line], context('2027-06-26T10:00:00Z', ''))).toThrow(
      ReturnTooLateError,
    );
    try {
      buildReturnReceipt(of, [line], context('2028-01-01T00:00:00Z', ''));
      expect.unreachable();
    } catch (err) {
      expect(err).toBeInstanceOf(ReturnTooLateError);
      expect((err as ReturnTooLateError).code).toBe('RETURN_TOO_LATE');
    }
  });

  it('needs the UUID of the sale receipt, and a return after the sale', () => {
    expect(() =>
      buildReturnReceipt({ ...of, uuid: '' }, [line], context('2026-01-05T12:00:00Z', '')),
    ).toThrow(RangeError);
    expect(() => buildReturnReceipt(of, [line], context('2025-12-31T23:59:59Z', ''))).toThrow(
      RangeError,
    );
  });
});
