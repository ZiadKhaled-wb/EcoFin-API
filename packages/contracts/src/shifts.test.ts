import { describe, it, expect } from 'vitest';
import {
  CurrentShift,
  ShiftSummary,
  ShiftCashBody,
  ShiftCloseBody,
  ShiftDifferenceDetail,
  ShiftListQuery,
  ShiftOpenBody,
  shiftCountTotal,
} from './shifts.js';
import { errorCodeHttpStatus } from './errors.js';

const BRANCH = 'a0600000-0000-4000-8000-000000000001';
const SAFE = 'a0600000-0000-4000-8000-000000000002';

describe('K02 shift contracts', () => {
  it('open: a float needs a safe, no float takes none; strict', () => {
    expect(ShiftOpenBody.safeParse({ branch_id: BRANCH, opening_float: '0' }).success).toBe(true);
    expect(
      ShiftOpenBody.safeParse({ branch_id: BRANCH, opening_float: '500.00', vault_id: SAFE })
        .success,
    ).toBe(true);
    expect(ShiftOpenBody.safeParse({ branch_id: BRANCH, opening_float: '500.00' }).success).toBe(
      false,
    );
    expect(
      ShiftOpenBody.safeParse({ branch_id: BRANCH, opening_float: '0.00', vault_id: SAFE }).success,
    ).toBe(false);
    for (const opening_float of ['-1.00', '1.234', 'abc']) {
      expect(
        ShiftOpenBody.safeParse({ branch_id: BRANCH, opening_float, vault_id: SAFE }).success,
      ).toBe(false);
    }
    expect(
      ShiftOpenBody.safeParse({ branch_id: BRANCH, opening_float: '0', organization_id: SAFE })
        .success,
    ).toBe(false);
  });

  it('cash: a direction, an amount above 0, a safe and a note', () => {
    const body = { direction: 'out', amount: '200.00', vault_id: SAFE, note: '  Too much ' };
    expect(ShiftCashBody.parse(body).note).toBe('Too much');
    expect(ShiftCashBody.safeParse({ ...body, direction: 'sideways' }).success).toBe(false);
    expect(ShiftCashBody.safeParse({ ...body, amount: '0.00' }).success).toBe(false);
    expect(ShiftCashBody.safeParse({ ...body, note: 'no' }).success).toBe(false);
  });

  it('close: counts by Egyptian notes and coins; the total is exact', () => {
    expect(ShiftCloseBody.safeParse({ counts: {} }).success).toBe(true);
    expect(
      ShiftCloseBody.safeParse({ counts: { '200': 3, '0.25': 2 }, vault_id: SAFE }).success,
    ).toBe(true);
    expect(ShiftCloseBody.safeParse({ counts: { '25': 1 } }).success).toBe(false);
    expect(ShiftCloseBody.safeParse({ counts: { '200': 1.5 } }).success).toBe(false);
    expect(ShiftCloseBody.safeParse({ counts: { '200': -1 } }).success).toBe(false);
    expect(shiftCountTotal({})).toBe('0.00');
    expect(shiftCountTotal({ '200': 3, '20': 2 })).toBe('640.00');
    expect(shiftCountTotal({ '0.5': 3, '0.25': 1, '1': 2 })).toBe('3.75');
  });

  it('list query, current shift, details and the error codes', () => {
    expect(ShiftListQuery.parse({ status: 'open' })).toMatchObject({ page: 1 });
    expect(ShiftListQuery.safeParse({ status: 'paused' }).success).toBe(false);
    expect(ShiftListQuery.safeParse({ from: '2026-10-02', to: '2026-10-01' }).success).toBe(false);
    expect(CurrentShift.parse({ shift: null }).shift).toBeNull();
    expect(
      ShiftDifferenceDetail.safeParse({
        expected: '400.00',
        counted: '390.00',
        difference: '-10.00',
      }).success,
    ).toBe(true);
    expect(errorCodeHttpStatus.SHIFT_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.SHIFT_ALREADY_OPEN).toBe(409);
    expect(errorCodeHttpStatus.SHIFT_CLOSED).toBe(409);
    expect(errorCodeHttpStatus.SHIFT_REQUIRED).toBe(409);
    expect(errorCodeHttpStatus.SHIFT_DIFFERENCE_REASON_REQUIRED).toBe(400);
    expect(errorCodeHttpStatus.DEVICE_INVALID).toBe(400);
  });
});

describe('EC-149 shift takings (D94)', () => {
  const zeros = { cash: '0.00', bank_transfer: '0.00', store_credit: '0.00' };
  const shift = {
    id: BRANCH,
    number: 'MAIN-SH-26-000001',
    branch_id: BRANCH,
    device_id: SAFE,
    device_name: 'POS 1',
    employee_id: SAFE,
    employee_name: 'Cashier',
    drawer_account_id: SAFE,
    status: 'closed',
    opening_float: '100.00',
    opened_at: '2026-10-22T08:00:00.000Z',
    closed_at: '2026-10-22T20:00:00.000Z',
    closed_by_name: 'Cashier',
    expected_cash: '29400.00',
    counted_cash: '29400.00',
    difference: '0.00',
    count_breakdown: { '200': 147 },
    difference_reason: null,
    sales_total: '69950.00',
    sales_count: 3,
    tax_total: '8590.35',
    payment_totals: { ...zeros, cash: '27200.00', bank_transfer: '22750.00' },
    collections: { ...zeros, cash: '2200.00' },
    deposits: { ...zeros, bank_transfer: '1000.00' },
  };
  it('a shift answers its sales count, VAT and collections apart from the sales money', () => {
    expect(ShiftSummary.safeParse(shift).success).toBe(true);
  });
  it('the takings fields are required on a shift', () => {
    const { collections: _c, ...noCollections } = shift;
    const { sales_count: _n, ...noCount } = shift;
    const { deposits: _d, ...noDeposits } = shift;
    expect(ShiftSummary.safeParse(noDeposits).success).toBe(false);
    expect(ShiftSummary.safeParse(noCollections).success).toBe(false);
    expect(ShiftSummary.safeParse(noCount).success).toBe(false);
  });
});
