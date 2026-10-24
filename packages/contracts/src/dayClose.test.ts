import { describe, expect, it } from 'vitest';
import {
  CloseDayBody,
  DayClose,
  DayCloseAlerts,
  DayCloseBlockedDetail,
  DayCloseListQuery,
  DayClosePreview,
  DayClosePreviewQuery,
  ReopenDayBody,
  dayCloseBlockers,
  dayCloseNeedsNote,
  type DayCloseIssue,
} from './dayClose.js';
import { errorCodeHttpStatus } from './errors.js';
import { PERMISSION_KEYS } from './permissions.js';

const ID = '11111111-1111-4111-8111-111111111111';
const ID2 = '22222222-2222-4222-8222-222222222222';
const ts = '2026-10-20T20:00:00.000Z';
const HASH = '0123456789abcdef0123456789abcdef';
const zeros = { cash: '0.00', bank_transfer: '0.00', store_credit: '0.00' };
const ct = { count: 0, total: '0.00' };

const totals = {
  sales: {
    count: 2,
    total: '800.00',
    discount_total: '0.00',
    tax_total: '98.25',
    paid_by_method: { cash: '500.00', bank_transfer: '300.00', store_credit: '0.00' },
    on_contract: '0.00',
    voided: ct,
  },
  returns: { count: 0, total: '0.00', refunded_by_method: zeros },
  collections: {
    count: 1,
    total: '1000.00',
    principal: '833.33',
    profit: '166.67',
    by_method: { ...zeros, cash: '1000.00' },
    in_field: '0.00',
    reversed: ct,
  },
  expenses: {
    count: 1,
    total: '150.00',
    by_category: [{ category_id: ID, name: 'Rent', total: '150.00' }],
    reversed: ct,
  },
  supplier_payments: { ...ct, reversed: ct },
  supplier_refunds: ct,
  cash: {
    accounts: [
      {
        account: { id: ID, name: 'Safe', kind: 'safe', shop_wide: false },
        opening: '0.00',
        in: '10000.00',
        out: '150.00',
        closing: '9850.00',
        by_type: { opening: '10000.00', expense: '-150.00' },
      },
      {
        account: { id: ID2, name: 'NBE', kind: 'bank', shop_wide: true },
        opening: null,
        in: '300.00',
        out: '0.00',
        closing: null,
        by_type: { sale: '300.00' },
      },
    ],
    total_closing_cash: '9850.00',
  },
  shifts: {
    items: [
      {
        id: ID,
        number: 'BR1-SH-26-000001',
        status: 'closed',
        cashier: { id: ID2, name: 'Cashier' },
        device_name: 'POS 1',
        opened_at: ts,
        closed_at: ts,
        opening_float: '500.00',
        expected: '1000.00',
        counted: '990.00',
        difference: '-10.00',
        difference_reason: 'Short',
        payment_totals: zeros,
      },
    ],
    difference_total: '-10.00',
  },
  eta: null,
};

const warning: DayCloseIssue = {
  code: 'ETA_NOT_ACCEPTED',
  severity: 'warning',
  params: { waiting: 2 },
  link: { kind: 'eta_monitor', id: ID },
};
const blocking: DayCloseIssue = {
  code: 'SHIFT_OPEN',
  severity: 'blocking',
  params: { number: 'BR1-SH-26-000002' },
  link: { kind: 'shift', id: ID2 },
};
const info: DayCloseIssue = {
  code: 'EARLIER_DAY_OPEN',
  severity: 'info',
  params: { count: 1, first_date: '2026-10-18' },
  link: { kind: 'day_list', id: ID },
};

describe('K04 preview and stored close', () => {
  const close = {
    id: ID,
    branch_id: ID2,
    branch_name: 'Main',
    business_date: '2026-10-20',
    status: 'closed',
    totals,
    issues: [info],
    note: null,
    closed_by: { id: ID, name: 'Owner' },
    closed_at: ts,
    reopened_by: null,
    reopened_at: null,
    reopen_reason: null,
    drift: false,
  };
  it('parses the server shapes (shop-wide bank without opening or closing)', () => {
    expect(DayClose.safeParse(close).success).toBe(true);
    const preview = {
      branch_id: ID2,
      branch_name: 'Main',
      business_date: '2026-10-20',
      status: 'reopened',
      is_today: true,
      totals,
      issues: [warning, info],
      hash: HASH,
      last_close: { ...close, drift: undefined },
    };
    expect(DayClosePreview.safeParse(preview).success).toBe(true);
    expect(DayClosePreview.safeParse({ ...preview, status: 'closed' }).success).toBe(false);
    expect(DayClosePreview.safeParse({ ...preview, hash: 'x' }).success).toBe(false);
  });
  it('refuses money as numbers', () => {
    const bad = { ...totals, sales: { ...totals.sales, total: 800 } };
    expect(DayClose.safeParse({ ...close, totals: bad }).success).toBe(false);
  });
});

describe('K04 bodies and queries', () => {
  it('close: a hash from the preview, an optional note up to 500 characters', () => {
    const ok = { branch_id: ID, business_date: '2026-10-20', preview_hash: HASH };
    expect(CloseDayBody.safeParse(ok).success).toBe(true);
    expect(CloseDayBody.safeParse({ ...ok, note: 'ETA down today' }).success).toBe(true);
    expect(CloseDayBody.safeParse({ ...ok, note: 'x'.repeat(501) }).success).toBe(false);
    expect(CloseDayBody.safeParse({ ...ok, preview_hash: 'ABC' }).success).toBe(false);
    expect(CloseDayBody.safeParse({ ...ok, business_date: '2026-02-30' }).success).toBe(false);
    expect(CloseDayBody.safeParse({ ...ok, organization_id: ID }).success).toBe(false);
  });
  it('reopen: a reason of 3 to 500 characters', () => {
    expect(ReopenDayBody.safeParse({ reason: 'Late receipt' }).success).toBe(true);
    expect(ReopenDayBody.safeParse({ reason: ' ab ' }).success).toBe(false);
    expect(ReopenDayBody.safeParse({}).success).toBe(false);
  });
  it('queries are strict', () => {
    expect(DayClosePreviewQuery.safeParse({ branch_id: ID, date: '2026-10-20' }).success).toBe(
      true,
    );
    expect(DayClosePreviewQuery.safeParse({ branch_id: ID }).success).toBe(false);
    expect(DayCloseListQuery.safeParse({ status: 'closed', from: '2026-10-01' }).success).toBe(
      true,
    );
    expect(DayCloseListQuery.safeParse({ status: 'done' }).success).toBe(false);
    expect(DayCloseListQuery.safeParse({ page: 2 }).success).toBe(false);
  });
  it('alerts', () => {
    const a = {
      branches: [
        {
          branch_id: ID,
          branch_name: 'Main',
          unclosed_days: ['2026-10-18'],
          last_check: {
            business_date: '2026-10-19',
            checked_at: ts,
            drift: false,
            warnings: 1,
            critical: 0,
          },
        },
      ],
    };
    expect(DayCloseAlerts.safeParse(a).success).toBe(true);
  });
});

describe('K04 issue rules', () => {
  it('a warning needs a note; only blocking issues stop the close', () => {
    expect(dayCloseNeedsNote([info])).toBe(false);
    expect(dayCloseNeedsNote([info, warning])).toBe(true);
    expect(dayCloseBlockers([info, warning])).toEqual([]);
    expect(dayCloseBlockers([blocking, warning])).toEqual([blocking]);
    expect(DayCloseBlockedDetail.safeParse({ issues: [blocking] }).success).toBe(true);
  });
});

describe('K04 error codes and permissions', () => {
  it('has the new codes with their statuses', () => {
    expect(errorCodeHttpStatus.DAY_ALREADY_CLOSED).toBe(409);
    expect(errorCodeHttpStatus.DAY_NOT_CLOSED).toBe(409);
    expect(errorCodeHttpStatus.DAY_CLOSE_BLOCKED).toBe(409);
    expect(errorCodeHttpStatus.DAY_CHANGED).toBe(409);
    expect(errorCodeHttpStatus.NOTE_REQUIRED).toBe(422);
    expect(errorCodeHttpStatus.DAY_CLOSED).toBe(409);
  });
  it('uses the baseline keys', () => {
    expect(PERMISSION_KEYS).toContain('day.close');
    expect(PERMISSION_KEYS).toContain('day.reopen');
  });
});

describe('EC-149 day close figures (D94)', () => {
  const base = {
    id: ID,
    branch_id: ID2,
    branch_name: 'Main',
    business_date: '2026-10-22',
    status: 'closed',
    issues: [],
    note: null,
    closed_by: { id: ID, name: 'Owner' },
    closed_at: ts,
    reopened_by: null,
    reopened_at: null,
    reopen_reason: null,
    drift: false,
  };
  it('a day closed since EC-149 carries the returns VAT and each shift takings', () => {
    const shift = {
      ...totals.shifts.items[0],
      sales_count: 3,
      sales_total: '800.00',
      tax_total: '98.25',
      collections: { ...zeros, cash: '1000.00' },
    };
    const now = {
      ...totals,
      returns: { ...totals.returns, tax_total: '0.00' },
      shifts: { ...totals.shifts, items: [shift] },
    };
    const parsed = DayClose.parse({ ...base, totals: now });
    expect(parsed.totals.returns.tax_total).toBe('0.00');
    expect(parsed.totals.shifts.items[0]?.collections?.cash).toBe('1000.00');
  });
  it('a day closed before EC-149 (no returns VAT, no shift takings) still parses', () => {
    const parsed = DayClose.parse({ ...base, totals });
    expect(parsed.totals.returns.tax_total).toBeUndefined();
    expect(parsed.totals.shifts.items[0]?.sales_count).toBeUndefined();
  });
});
