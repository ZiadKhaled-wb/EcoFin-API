import {
  addMoney,
  computeDocumentTax,
  multiplyMoney,
  percentOf,
  roundMoney,
  subtractMoney,
  sumMoney,
} from '@ziadkhaled-wb/contracts';
import { expect, it } from 'vitest';
import { buildReceipt, type ReceiptSource } from './build-receipt';
import { toJson } from '@ziadkhaled-wb/contracts';
import { receiptUuid, type HasReceiptHeader } from './uuid';
import { parseExactJson } from '../test/eta-json';

const SEED = 4242;
// Integer PRNG only generates inputs; all monetary calculations use T01/F12.
function random(seed: number) {
  let state = seed;
  return (limit: number) => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state % limit;
  };
}
const money = (cents: number) =>
  `${Math.floor(cents / 100)}.${String(cents % 100).padStart(2, '0')}`;

it('TEST4: 5000 seeded ETA snapshots obey every arithmetic and exact-byte UUID rule', () => {
  const next = random(SEED);
  for (let index = 0; index < 5000; index++) {
    const input = {
      prices_include_vat: next(2) === 0,
      lines: Array.from({ length: 1 + next(4) }, (_, line) => {
        const unit_price = money(1 + next(9999999));
        const quantity = 1 + next(20);
        return {
          unit_price,
          quantity,
          line_discount:
            line < 3 ? percentOf(multiplyMoney(unit_price, quantity), String(next(6))) : '0.00',
          tax_rate: next(3) === 0 ? '14.00' : '0.00',
        };
      }),
      document_discount: '0.00',
    };
    input.document_discount = percentOf(
      sumMoney(
        input.lines.map((l) =>
          subtractMoney(multiplyMoney(l.unit_price, l.quantity), l.line_discount),
        ),
      ),
      String(next(6)),
    );
    try {
      const priced = computeDocumentTax(input);
      const source: ReceiptSource = {
        sale: {
          number: `TEST4-${index}`,
          issued_at: '2026-10-12T09:15:02Z',
          prices_include_vat: input.prices_include_vat,
          total: priced.total,
        },
        lines: priced.lines.map((line, i) => ({
          line_no: i + 1,
          quantity: input.lines[i]!.quantity,
          unit_price: input.lines[i]!.unit_price,
          discount_amount: line.discount_amount,
          tax_rate: line.tax_rate,
          tax_amount: line.tax,
          line_total: line.gross,
          sku: `SKU-${i}`,
          name: `Product ${i}`,
          eta_item_code: `EG-674859545-${i}`,
          eta_item_type: 'EGS',
          eta_tax_type: 'T1',
          eta_subtype: line.tax_rate === '14.00' ? 'V009' : i % 2 === 0 ? 'V001' : 'V003',
        })),
        payments: [{ method: 'cash', amount: priced.total }],
        customer: {
          name: 'Buyer',
          national_id: '29901011234567',
          is_business: false,
          tax_registration_no: null,
        },
        seller: {
          rin: '674859545',
          name: 'Shop',
          activity_code: '4753',
          branch_code: '0',
          governorate: 'Cairo',
          city: 'Nasr City',
          street: 'Main',
          building_number: '1',
        },
        device: { serial: 'TEST4-POS', status: 'active', is_active: true },
      };
      const receipt = buildReceipt(source, '');
      expect(receipt.totalAmount.text).toBe(priced.total);
      expect(sumMoney(receipt.taxTotals.map((t) => t.amount.text))).toBe(priced.tax_total);
      expect(receipt.totalSales.text).toBe(sumMoney(receipt.itemData.map((l) => l.totalSale.text)));
      expect(receipt.totalCommercialDiscount.text).toBe(
        sumMoney(
          receipt.itemData.flatMap((l) =>
            (l.commercialDiscountData ?? []).map((d) => d.amount.text),
          ),
        ),
      );
      expect(receipt.netAmount.text).toBe(sumMoney(receipt.itemData.map((l) => l.netSale.text)));
      expect(receipt.totalAmount.text).toBe(
        addMoney(sumMoney(receipt.itemData.map((l) => l.total.text)), receipt.adjustment.text),
      );
      for (const item of receipt.itemData) {
        expect(
          subtractMoney(
            item.totalSale.text,
            sumMoney((item.commercialDiscountData ?? []).map((d) => d.amount.text)),
          ),
        ).toBe(item.netSale.text);
        expect(
          addMoney(item.netSale.text, sumMoney(item.taxableItems.map((t) => t.amount.text))),
        ).toBe(item.total.text);
        // 5-decimal unit prices x bounded integer quantity, compared exactly as integer 1/100000 units.
        const scaled = BigInt(item.unitPrice.text.replace('.', '')) * BigInt(item.quantity.text);
        const expected = BigInt(item.totalSale.text.replace('.', '')) * 1000n;
        const difference = scaled > expected ? scaled - expected : expected - scaled;
        expect(difference <= 50000n).toBe(true); // spec tolerance 0.5
        expect(item.unitPrice.text).toMatch(/^\d+\.\d{5}$/);
        expect(item.quantity.text).toMatch(/^\d+$/);
        for (const amount of [
          item.totalSale,
          item.netSale,
          item.total,
          ...item.taxableItems.map((t) => t.amount),
        ])
          expect(amount.text).toMatch(/^\d+\.\d{2}$/);
        for (const tax of item.taxableItems) {
          expect(tax.rate.text).toMatch(/^\d+\.\d{2}$/);
          const delta = subtractMoney(tax.amount.text, percentOf(item.netSale.text, tax.rate.text));
          expect(
            BigInt(roundMoney(delta).replace('.', '')) >= -50n &&
              BigInt(delta.replace('.', '')) <= 50n,
          ).toBe(true);
          expect(receipt.taxTotals.find((t) => t.taxType === tax.taxType)?.amount.text).toBe(
            sumMoney(
              receipt.itemData.flatMap((l) =>
                l.taxableItems.filter((t) => t.taxType === tax.taxType).map((t) => t.amount.text),
              ),
            ),
          );
        }
      }
      // Same exact-byte parser and UUID recomputation used by the fake ETA.
      expect(receiptUuid(parseExactJson(toJson(receipt)) as HasReceiptHeader)).toBe(
        receipt.header.uuid,
      );
    } catch (error) {
      throw new Error(`seed=${SEED} case=${index} input=${JSON.stringify(input)}`, {
        cause: error,
      });
    }
  }
}, 60000);
