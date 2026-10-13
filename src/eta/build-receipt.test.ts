import { addMoney, computeDocumentTax, sumMoney } from '@ziadkhaled-wb/contracts';
import { describe, expect, it } from 'vitest';
import {
  buildReceipt,
  paymentMethodCode,
  ReceiptBlockedError,
  type Receipt,
  type ReceiptSource,
  type SourceLine,
} from './build-receipt';
import { serialize, toJson } from './serialize';
import { receiptUuid } from './uuid';

const NATIONAL_ID = '29901011234567';

const line = (over: Partial<SourceLine> = {}): SourceLine => ({
  line_no: 1,
  quantity: 1,
  unit_price: '1140.00',
  discount_amount: '0.00',
  tax_rate: '14.00',
  tax_amount: '140.00',
  line_total: '1140.00',
  sku: 'TV-55',
  name: 'تلفزيون 55 بوصة',
  eta_item_code: 'EG-674859545-TV55',
  eta_item_type: 'EGS',
  eta_tax_type: 'T1',
  eta_subtype: 'V009',
  ...over,
});

function source(over: Partial<ReceiptSource> = {}, lines: SourceLine[] = [line()]): ReceiptSource {
  return {
    sale: {
      number: 'MAIN-SL-26-000001',
      issued_at: '2026-10-12T09:15:02Z',
      prices_include_vat: true,
      total: sumMoney(lines.map((l) => l.line_total)),
    },
    lines,
    payments: [{ method: 'cash', amount: sumMoney(lines.map((l) => l.line_total)) }],
    customer: null,
    seller: {
      rin: '674859545',
      name: 'شركة النور للأثاث',
      activity_code: '4753',
      branch_code: '0',
      governorate: 'Cairo',
      city: 'Nasr City',
      street: '16 Abbas El Akkad',
      building_number: '14',
    },
    device: { serial: 'POS-001', status: 'active', is_active: true },
    ...over,
  };
}

/** The receipt, or the code it is blocked with. */
function blockOf(src: ReceiptSource): string {
  try {
    buildReceipt(src, '');
  } catch (err) {
    if (err instanceof ReceiptBlockedError) return err.code;
    throw err;
  }
  return 'built';
}

const texts = (receipt: Receipt) => ({
  totalSales: receipt.totalSales.text,
  totalCommercialDiscount: receipt.totalCommercialDiscount.text,
  netAmount: receipt.netAmount.text,
  totalAmount: receipt.totalAmount.text,
  taxTotals: receipt.taxTotals.map((tax) => `${tax.taxType}:${tax.amount.text}`),
});

describe('ETA receipt builder: amounts', () => {
  it('prices include VAT, 14%: 1140.00 with a 114.00 discount', () => {
    const receipt = buildReceipt(
      source({}, [
        line({ discount_amount: '114.00', tax_amount: '126.00', line_total: '1026.00' }),
      ]),
      '',
    );
    const [item] = receipt.itemData;
    expect(item?.netSale.text).toBe('900.00');
    expect(item?.taxableItems).toHaveLength(1);
    expect(item?.taxableItems[0]?.amount.text).toBe('126.00');
    expect(item?.total.text).toBe('1026.00');
    expect(receipt.totalAmount.text).toBe('1026.00');
    // The discount without its VAT, and the price before it: what the ETA re-computes.
    expect(item?.commercialDiscountData?.[0]?.amount.text).toBe('100.00');
    expect(item?.totalSale.text).toBe('1000.00');
    expect(item?.unitPrice.text).toBe('1000.00000');
    expect(item?.quantity.text).toBe('1');
    expect(texts(receipt)).toEqual({
      totalSales: '1000.00',
      totalCommercialDiscount: '100.00',
      netAmount: '900.00',
      totalAmount: '1026.00',
      taxTotals: ['T1:126.00'],
    });
  });

  it('prices exclude VAT: 1000.00 with 10% off gives the same ETA figures', () => {
    const withVat = buildReceipt(
      source({}, [
        line({ discount_amount: '114.00', tax_amount: '126.00', line_total: '1026.00' }),
      ]),
      '',
    );
    const withoutVat = buildReceipt(
      source({ sale: { ...source().sale, prices_include_vat: false, total: '1026.00' } }, [
        line({
          unit_price: '1000.00',
          discount_amount: '100.00',
          tax_amount: '126.00',
          line_total: '1026.00',
        }),
      ]),
      '',
    );
    expect(toJson(withoutVat.itemData)).toBe(toJson(withVat.itemData));
    expect(texts(withoutVat)).toEqual(texts(withVat));
    expect(withoutVat.itemData[0]?.unitPrice.text).toBe('1000.00000');
  });

  it.each([true, false])(
    'three lines with a whole-sale discount spread: totals equal the sale exactly (prices include VAT: %s)',
    (pricesIncludeVat) => {
      // The sale as T01 computes and S03 stores it: a 100.00 sale discount over three lines.
      const priced = computeDocumentTax({
        prices_include_vat: pricesIncludeVat,
        document_discount: '100.00',
        lines: [
          { unit_price: '333.33', quantity: 1, tax_rate: '14' },
          { unit_price: '199.99', quantity: 3, line_discount: '10.00', tax_rate: '14' },
          { unit_price: '50.00', quantity: 7, tax_rate: '0' },
        ],
      });
      const lines = priced.lines.map((l, i) =>
        line({
          line_no: i + 1,
          quantity: [1, 3, 7][i] ?? 1,
          unit_price: ['333.33', '199.99', '50.00'][i] ?? '0.00',
          discount_amount: l.discount_amount,
          tax_rate: i === 2 ? '0.00' : '14.00',
          tax_amount: l.tax,
          line_total: l.gross,
          sku: `SKU-${i + 1}`,
          eta_subtype: i === 2 ? 'V003' : 'V009',
        }),
      );
      const receipt = buildReceipt(
        source(
          { sale: { ...source().sale, prices_include_vat: pricesIncludeVat, total: priced.total } },
          lines,
        ),
        '',
      );

      expect(receipt.totalAmount.text).toBe(priced.total);
      expect(receipt.netAmount.text).toBe(priced.net_total);
      expect(receipt.taxTotals).toHaveLength(1);
      expect(receipt.taxTotals[0]?.amount.text).toBe(priced.tax_total);
      expect(receipt.itemData.map((item) => item.total.text)).toEqual(
        priced.lines.map((l) => l.gross),
      );
      expect(sumMoney(receipt.itemData.map((item) => item.total.text))).toBe(priced.total);

      for (const item of receipt.itemData) {
        const discount = sumMoney((item.commercialDiscountData ?? []).map((d) => d.amount.text));
        // The ETA's own equations hold to the piaster (its tolerance is 0.5).
        expect(addMoney(item.netSale.text, discount)).toBe(item.totalSale.text);
        expect(addMoney(item.netSale.text, item.taxableItems[0]?.amount.text ?? '0.00')).toBe(
          item.total.text,
        );
        const recomputed = Number(item.unitPrice.text) * Number(item.quantity.text);
        expect(Math.abs(recomputed - Number(item.totalSale.text))).toBeLessThan(0.001);
        expect(item.unitPrice.text).toMatch(/^\d+\.\d{5}$/);
      }
      expect(receipt.totalSales.text).toBe(sumMoney(receipt.itemData.map((i) => i.totalSale.text)));
      expect(receipt.totalCommercialDiscount.text).toBe(
        sumMoney(
          receipt.itemData.flatMap((i) =>
            (i.commercialDiscountData ?? []).map((d) => d.amount.text),
          ),
        ),
      );
      if (!pricesIncludeVat)
        expect(receipt.totalCommercialDiscount.text).toBe(priced.discount_total);
    },
  );

  it('a 0% / exempt line carries the exempt subtype, rate 0 and no tax', () => {
    const receipt = buildReceipt(
      source({}, [
        line({
          tax_rate: '0.00',
          tax_amount: '0.00',
          line_total: '500.00',
          unit_price: '500.00',
          eta_subtype: 'V003',
        }),
      ]),
      '',
    );
    expect(receipt.itemData[0]?.taxableItems).toEqual([
      { taxType: 'T1', amount: { text: '0.00' }, subType: 'V003', rate: { text: '0.00' } },
    ]);
    expect(receipt.itemData[0]?.netSale.text).toBe('500.00');
    expect(receipt.taxTotals[0]?.amount.text).toBe('0.00');
    expect(receipt.itemData[0]?.commercialDiscountData).toBeUndefined();
  });

  it('never lets a receipt out whose lines do not add up to the sale', () => {
    const src = source();
    expect(() => buildReceipt({ ...src, sale: { ...src.sale, total: '1140.01' } }, '')).toThrow(
      /do not add up/,
    );
  });

  it('writes the properties in the order the SDK lists them', () => {
    const receipt = buildReceipt(
      source({}, [
        line({ discount_amount: '114.00', tax_amount: '126.00', line_total: '1026.00' }),
      ]),
      '',
    );
    expect(Object.keys(receipt)).toEqual([
      'header',
      'documentType',
      'seller',
      'buyer',
      'itemData',
      'totalSales',
      'totalCommercialDiscount',
      'totalItemsDiscount',
      'netAmount',
      'feesAmount',
      'totalAmount',
      'taxTotals',
      'paymentMethod',
      'adjustment',
    ]);
    expect(Object.keys(receipt.header)).toEqual([
      'dateTimeIssued',
      'receiptNumber',
      'uuid',
      'previousUUID',
      'referenceOldUUID',
      'currency',
      'exchangeRate',
    ]);
    expect(Object.keys(receipt.itemData[0] ?? {})).toEqual([
      'internalCode',
      'description',
      'itemType',
      'itemCode',
      'unitType',
      'quantity',
      'unitPrice',
      'netSale',
      'totalSale',
      'total',
      'commercialDiscountData',
      'taxableItems',
    ]);
    expect(receipt.documentType).toEqual({ receiptType: 's', typeVersion: '1.2' });
    expect(receipt.seller).toEqual({
      rin: '674859545',
      companyTradeName: 'شركة النور للأثاث',
      branchCode: '0',
      branchAddress: {
        country: 'EG',
        governate: 'Cairo',
        regionCity: 'Nasr City',
        street: '16 Abbas El Akkad',
        buildingNumber: '14',
      },
      deviceSerialNumber: 'POS-001',
      activityCode: '4753',
    });
    expect(receipt.header).toMatchObject({
      dateTimeIssued: '2026-10-12T09:15:02Z',
      receiptNumber: 'MAIN-SL-26-000001',
      previousUUID: '',
      referenceOldUUID: '',
      currency: 'EGP',
    });
    expect(toJson(receipt)).toContain('"currency":"EGP","exchangeRate":0}');
    expect(toJson(receipt)).toContain('"feesAmount":0,');
    expect(toJson(receipt)).toMatch(/"adjustment":0\}$/);
  });

  it('carries its own UUID, chained to the previous receipt', () => {
    const first = buildReceipt(source(), '');
    const second = buildReceipt(
      source({ sale: { ...source().sale, number: 'MAIN-SL-26-000002' } }),
      first.header.uuid,
    );
    expect(first.header.uuid).toMatch(/^[0-9a-f]{64}$/);
    expect(first.header.uuid).toBe(receiptUuid(first));
    expect(second.header.previousUUID).toBe(first.header.uuid);
    expect(second.header.uuid).not.toBe(first.header.uuid);
    // The same sale built again gives the same receipt: a retry can't fork the chain.
    expect(buildReceipt(source(), '').header.uuid).toBe(first.header.uuid);
    expect(serialize(first)).toContain('"PREVIOUSUUID""""REFERENCEOLDUUID"""');
    expect(() => buildReceipt(source(), 'not-a-uuid')).toThrow(RangeError);
  });

  it('keeps quotes and control characters out of names', () => {
    const receipt = buildReceipt(
      source({}, [line({ name: ' كنبة "مودرن"\n3 مقاعد ', sku: 'S\\1' })]),
      '',
    );
    expect(receipt.itemData[0]?.description).toBe("كنبة 'مودرن' 3 مقاعد");
    expect(receipt.itemData[0]?.internalCode).toBe('S/1');
  });
});

describe('ETA receipt builder: buyer', () => {
  const big = [line({ unit_price: '150000.00', tax_amount: '18421.05', line_total: '150000.00' })];
  const person = {
    name: 'Mona Adel',
    national_id: NATIONAL_ID,
    is_business: false,
    tax_registration_no: null,
  };

  it('a walk-in buyer is a person with no ID', () => {
    const receipt = buildReceipt(source(), '');
    expect(receipt.buyer).toEqual({ type: 'P' });
    expect(toJson(receipt)).toContain('"buyer":{"type":"P"}');
  });

  it('a known person below the threshold: the name, never the national ID', () => {
    const receipt = buildReceipt(source({ customer: person }), '');
    expect(receipt.buyer).toEqual({ type: 'P', name: 'Mona Adel' });
    expect(toJson(receipt)).not.toContain(NATIONAL_ID);
  });

  it('a business customer is B with its RIN', () => {
    const receipt = buildReceipt(
      source({
        customer: {
          name: 'Delta Trading',
          national_id: null,
          is_business: true,
          tax_registration_no: '313-717-919',
        },
      }),
      '',
    );
    expect(receipt.buyer).toEqual({ type: 'B', id: '313717919', name: 'Delta Trading' });
    expect(Object.keys(receipt.buyer)).toEqual(['type', 'id', 'name']);
  });

  it('a person at 150,000.00 needs a national ID and a name', () => {
    expect(blockOf(source({ customer: null }, big))).toBe('BLOCKED:BUYER_ID');
    expect(blockOf(source({ customer: { ...person, national_id: null } }, big))).toBe(
      'BLOCKED:BUYER_ID',
    );
    expect(blockOf(source({ customer: { ...person, national_id: '123' } }, big))).toBe(
      'BLOCKED:BUYER_ID',
    );
    const receipt = buildReceipt(source({ customer: person }, big), '');
    expect(receipt.buyer).toEqual({ type: 'P', id: NATIONAL_ID, name: 'Mona Adel' });
  });

  it('one piaster below 150,000.00 needs no ID', () => {
    const below = [
      line({ unit_price: '149999.99', tax_amount: '18421.05', line_total: '149999.99' }),
    ];
    expect(buildReceipt(source({ customer: null }, below), '').buyer).toEqual({ type: 'P' });
  });

  it('a business without a 9-digit RIN, or with the shop own RIN, is blocked', () => {
    const business = {
      name: 'Delta',
      national_id: null,
      is_business: true,
      tax_registration_no: '12345',
    };
    expect(blockOf(source({ customer: business }))).toBe('BLOCKED:BUYER_ID');
    expect(blockOf(source({ customer: { ...business, tax_registration_no: '674859545' } }))).toBe(
      'BLOCKED:BUYER_ID',
    );
  });

  it('a blocked receipt never quotes the national ID', () => {
    try {
      buildReceipt(source({ customer: { ...person, name: '' } }, big), '');
      expect.unreachable();
    } catch (err) {
      expect(err).toBeInstanceOf(ReceiptBlockedError);
      expect((err as Error).message).not.toContain(NATIONAL_ID);
    }
  });
});

describe('ETA receipt builder: blocked receipts', () => {
  it('a product without an ETA code or type is BLOCKED:ITEM_CODE, naming the SKU', () => {
    expect(blockOf(source({}, [line({ eta_item_code: null })]))).toBe('BLOCKED:ITEM_CODE');
    expect(blockOf(source({}, [line({ eta_item_code: '  ' })]))).toBe('BLOCKED:ITEM_CODE');
    expect(blockOf(source({}, [line({ eta_item_type: null })]))).toBe('BLOCKED:ITEM_CODE');
    expect(blockOf(source({}, [line({ eta_item_type: 'GPC' })]))).toBe('BLOCKED:ITEM_CODE');
    expect(() =>
      buildReceipt(
        source({}, [line(), line({ line_no: 2, sku: 'SOFA-3', eta_item_code: null })]),
        '',
      ),
    ).toThrow(/SOFA-3/);
    expect(
      blockOf(source({}, [line({ eta_item_type: 'GS1', eta_item_code: '037000401629' })])),
    ).toBe('built');
  });

  it('no device, or a device that is not active with the ETA, is BLOCKED:NO_DEVICE', () => {
    expect(blockOf(source({ device: null }))).toBe('BLOCKED:NO_DEVICE');
    for (const device of [
      { serial: 'POS-001', status: 'pending', is_active: true },
      { serial: 'POS-001', status: 'revoked', is_active: true },
      { serial: 'POS-001', status: 'active', is_active: false },
      { serial: null, status: 'active', is_active: true },
    ]) {
      expect(blockOf(source({ device }))).toBe('BLOCKED:NO_DEVICE');
    }
  });

  it.each([
    ['rin', null],
    ['rin', '12345'],
    ['name', ''],
    ['activity_code', null],
    ['branch_code', null],
    ['governorate', null],
    ['city', ''],
    ['street', null],
    ['building_number', null],
  ] as const)('seller data without a valid %s is BLOCKED:SELLER_DATA', (field, value) => {
    const src = source();
    expect(blockOf({ ...src, seller: { ...src.seller, [field]: value } })).toBe(
      'BLOCKED:SELLER_DATA',
    );
  });

  it('checks the device first, then the seller, the items and the buyer', () => {
    const src = source({ device: null }, [line({ eta_item_code: null })]);
    expect(blockOf({ ...src, seller: { ...src.seller, rin: null } })).toBe('BLOCKED:NO_DEVICE');
    const withDevice = source({}, [line({ eta_item_code: null })]);
    expect(blockOf({ ...withDevice, seller: { ...withDevice.seller, rin: null } })).toBe(
      'BLOCKED:SELLER_DATA',
    );
  });
});

describe('ETA receipt builder: payment method', () => {
  it('cash is C; a bank transfer and store credit are O (the SDK has no code for them)', () => {
    expect(paymentMethodCode([{ method: 'cash', amount: '100.00' }])).toBe('C');
    expect(paymentMethodCode([{ method: 'bank_transfer', amount: '100.00' }])).toBe('O');
    expect(paymentMethodCode([{ method: 'store_credit', amount: '100.00' }])).toBe('O');
    expect(paymentMethodCode([])).toBe('C');
  });

  it('a mixed payment takes the code with the largest share; cash wins a tie', () => {
    expect(
      paymentMethodCode([
        { method: 'cash', amount: '400.00' },
        { method: 'bank_transfer', amount: '600.00' },
      ]),
    ).toBe('O');
    expect(
      paymentMethodCode([
        { method: 'cash', amount: '600.00' },
        { method: 'bank_transfer', amount: '400.00' },
      ]),
    ).toBe('C');
    // Two transfers and store credit together outweigh the cash.
    expect(
      paymentMethodCode([
        { method: 'cash', amount: '400.00' },
        { method: 'bank_transfer', amount: '250.00' },
        { method: 'bank_transfer', amount: '100.00' },
        { method: 'store_credit', amount: '100.00' },
      ]),
    ).toBe('O');
    expect(
      paymentMethodCode([
        { method: 'cash', amount: '500.00' },
        { method: 'bank_transfer', amount: '500.00' },
      ]),
    ).toBe('C');
  });

  it('the receipt carries the code of its payments', () => {
    const receipt = buildReceipt(
      source({ payments: [{ method: 'bank_transfer', amount: '1140.00' }] }),
      '',
    );
    expect(receipt.paymentMethod).toBe('O');
  });
});
