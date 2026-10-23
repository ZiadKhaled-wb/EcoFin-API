import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  computeOfflineTotals,
  offlineActionsFor,
  offlineItemDone,
  OfflineContent,
  OfflineResolveBody,
  offlineSaleNumber,
  OfflineSettingsBody,
  OFFLINE_SUPPORTED_VERSIONS,
  readOfflineContent,
  writeOfflineContent,
  type OfflineContentFields,
} from './offline';
import { parseEtaJson } from './eta/json';
import { serialize, toJson, dec } from './eta/serialize';

interface TotalsCase {
  id: string;
  prices_include_vat: boolean;
  lines: { unit_price: string; quantity: number; tax_rate: string }[];
  expected: {
    lines: { tax_amount: string; line_total: string }[];
    subtotal: string;
    tax_total: string;
    total: string;
  };
}

// Written by S1 (supabase/tests/s08_offline_test.sql) from T01's SQL function.
const fixture = JSON.parse(
  readFileSync(
    new URL('../../../supabase/tests/fixtures/s08_offline_totals.json', import.meta.url),
    'utf8',
  ),
) as { cases: TotalsCase[] };

describe('U2 computeOfflineTotals equals T01 in SQL', () => {
  it('covers VAT included and excluded, 0%, quantity above 1, three lines at the half', () => {
    const cases = fixture.cases;
    expect(cases.some((c) => c.prices_include_vat)).toBe(true);
    expect(cases.some((c) => !c.prices_include_vat)).toBe(true);
    expect(cases.some((c) => c.lines.some((l) => l.tax_rate === '0.00'))).toBe(true);
    expect(cases.some((c) => c.lines.some((l) => l.quantity > 1))).toBe(true);
    expect(cases.filter((c) => c.lines.length === 3).length).toBeGreaterThanOrEqual(2);
  });

  it.each(fixture.cases.map((c) => [c.id, c] as const))('%s', (_id, c) => {
    expect(computeOfflineTotals(c.lines, c.prices_include_vat)).toEqual(c.expected);
  });
});

const fields = (over: Partial<OfflineContentFields> = {}): OfflineContentFields => ({
  lease_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2a01',
  device_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2a02',
  seq: 123,
  number: 'OFF-D2-000123',
  idempotency_key: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2a03',
  issued_at: '2026-10-23T09:15:02Z',
  cashier_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2a04',
  lines: [
    {
      product_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2a05',
      unit_id: null,
      quantity: 1,
      unit_price: '1140.00',
      tax_rate: '14.00',
      tax_amount: '140.00',
      line_total: '1140.00',
    },
  ],
  subtotal: '1140.00',
  tax_total: '140.00',
  total: '1140.00',
  payments: [{ method: 'cash', amount: '1140.00', tendered: '1200.00', change: '60.00' }],
  ...over,
});

describe('U6 the content schema', () => {
  const content = writeOfflineContent(fields(), null);

  it('reads back what the writer wrote, in the D6 order', () => {
    expect(readOfflineContent(content)).toEqual({ v: 1, ...fields(), receipt: null });
    expect(Object.keys(JSON.parse(content) as object)).toEqual([
      'v',
      'lease_id',
      'device_id',
      'seq',
      'number',
      'idempotency_key',
      'issued_at',
      'cashier_id',
      'lines',
      'subtotal',
      'tax_total',
      'total',
      'payments',
      'receipt',
    ]);
  });

  it('rejects an unknown field at the top, in a line and in a payment', () => {
    const parsed = JSON.parse(content) as Record<string, unknown> & {
      lines: Record<string, unknown>[];
      payments: Record<string, unknown>[];
    };
    expect(OfflineContent.safeParse({ ...parsed, customer_id: null }).success).toBe(false);
    expect(
      OfflineContent.safeParse({ ...parsed, lines: [{ ...parsed.lines[0], discount: '1.00' }] })
        .success,
    ).toBe(false);
    expect(
      OfflineContent.safeParse({ ...parsed, payments: [{ ...parsed.payments[0], card: '1' }] })
        .success,
    ).toBe(false);
  });

  it('rejects negative money anywhere', () => {
    const bad = [
      fields({ total: '-1140.00' }),
      fields({ subtotal: '-1.00' }),
      fields({
        payments: [{ method: 'cash', amount: '1140.00', tendered: '-1.00', change: '0.00' }],
      }),
      fields({
        lines: [{ ...fields().lines[0]!, unit_price: '-1140.00' }],
      }),
    ];
    for (const f of bad) expect(readOfflineContent(writeOfflineContent(f, null))).toBeNull();
  });

  it('rejects a version outside the supported list, and a card payment', () => {
    expect(OFFLINE_SUPPORTED_VERSIONS).toEqual([1]);
    const parsed = JSON.parse(content) as Record<string, unknown>;
    expect(OfflineContent.safeParse({ ...parsed, v: 2 }).success).toBe(false);
    expect(OfflineContent.safeParse({ ...parsed, v: 0 }).success).toBe(false);
    expect(
      OfflineContent.safeParse({
        ...parsed,
        payments: [{ method: 'card', amount: '1140.00', tendered: '1140.00', change: '0.00' }],
      }).success,
    ).toBe(false);
  });

  it('a serialized line has quantity 1; an unparsable text is no content', () => {
    const line = {
      ...fields().lines[0]!,
      unit_id: '6f1c4a59-62a4-4c6e-8a0b-2a8f1f6f2a06',
      quantity: 2,
    };
    expect(readOfflineContent(writeOfflineContent(fields({ lines: [line] }), null))).toBeNull();
    expect(readOfflineContent('{"v":1')).toBeNull();
  });

  it('carries the receipt JSON text unchanged (numbers keep their text)', () => {
    const receipt = { header: { uuid: 'a'.repeat(64) }, totalAmount: dec('1140.00') };
    const text = writeOfflineContent(fields(), toJson(receipt));
    expect(text.endsWith(`"receipt":${toJson(receipt)}}`)).toBe(true);
    expect(text).toContain('"totalAmount":1140.00');
  });
});

describe('offline numbers, actions and settings', () => {
  it('numbers the sale OFF-<code>-<seq padded to 6>', () => {
    expect(offlineSaleNumber('D2', 123)).toBe('OFF-D2-000123');
    expect(offlineSaleNumber('D10', 1234567)).toBe('OFF-D10-1234567');
    expect(() => offlineSaleNumber('X', 1)).toThrow(RangeError);
  });

  it('D11: the actions follow the conflict code and the hold', () => {
    const at = (status: 'received' | 'conflict', code: string | null, hold: string | null = null) =>
      offlineActionsFor({ status, conflict_code: code, fiscal_hold: hold });
    expect(at('conflict', 'TIME_INVALID')).toEqual(['accept']);
    expect(at('conflict', 'LIMIT_EXCEEDED')).toEqual(['accept']);
    expect(at('conflict', 'PRICE_MISMATCH')).toEqual(['accept']);
    expect(at('conflict', 'SERIAL_UNAVAILABLE')).toEqual(['use_serial']);
    expect(at('conflict', 'SHIFT_CLOSED')).toEqual(['post_to_shift']);
    expect(at('conflict', 'TOTALS_MISMATCH')).toEqual([]);
    expect(at('received', null, 'LEASE_REVOKED')).toEqual(['accept', 'reject']);
    expect(at('received', null, 'RECEIPT_MISMATCH')).toEqual([]);
  });

  it('a reason of 3 characters at least; settings within the D4 bounds', () => {
    expect(OfflineResolveBody.safeParse({ action: 'accept', reason: 'ok' }).success).toBe(false);
    expect(OfflineResolveBody.safeParse({ action: 'accept', reason: 'late ok' }).success).toBe(
      true,
    );
    const good = {
      offline_enabled: true,
      offline_max_sale_total: '20000.00',
      offline_max_hours: 12,
      offline_max_sales: 100,
      offline_max_lease_total: '200000.00',
    };
    expect(OfflineSettingsBody.safeParse(good).success).toBe(true);
    expect(
      OfflineSettingsBody.safeParse({ ...good, offline_max_sale_total: '150000.00' }).success,
    ).toBe(false);
    expect(OfflineSettingsBody.safeParse({ ...good, offline_max_hours: 21 }).success).toBe(false);
    expect(OfflineSettingsBody.safeParse({ ...good, offline_max_sales: 0 }).success).toBe(false);
  });

  it('only retry_later stays on the device', () => {
    expect(offlineItemDone('received')).toBe(true);
    expect(offlineItemDone('duplicate')).toBe(true);
    expect(offlineItemDone('rejected')).toBe(true);
    expect(offlineItemDone('retry_later')).toBe(false);
  });
});

describe('parseEtaJson keeps the number text', () => {
  it('serializes back to the same text, and a ": 5," in a name stays a string', () => {
    const json = '{"name":"TV: 55, black","amount":10.50,"items":[{"q":1},{"q":2.000}]}';
    const parsed = parseEtaJson(json);
    expect(toJson(parsed)).toBe(json);
    expect(serialize(parsed)).toBe(
      '"NAME""TV: 55, black""AMOUNT""10.50""ITEMS""ITEMS""Q""1""ITEMS""Q""2.000"',
    );
  });

  it('refuses what a receipt never holds', () => {
    for (const bad of [
      '{"a":true}',
      '{"a":null}',
      '{"a":1e3}',
      '{"a":1,"a":2}',
      '{"a":1} x',
      '[01]',
    ]) {
      expect(() => parseEtaJson(bad)).toThrow();
    }
  });
});
