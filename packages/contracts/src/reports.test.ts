import { describe, expect, it } from 'vitest';
import {
  RECEIVABLES_BUCKETS,
  RECEIVABLES_GROUP_BY,
  ReceivablesQuery,
  ReceivablesReport,
  ReceivablesRow,
  SALES_REPORT_COST_SORTS,
  SALES_REPORT_GROUP_BY,
  SalesReport,
  SalesReportQuery,
  SalesReportRow,
  salesReportDays,
} from './reports.js';

const ID = '11111111-1111-4111-8111-111111111111';
const ts = '2026-10-22T10:00:00.000Z';

const measures = {
  sales_count: 3,
  quantity: 11,
  revenue: '1777.19',
  gross: '1900.00',
  tax: '122.81',
  discount: '0.00',
  cost: '1220.00',
  margin: '557.19',
  margin_pct: '31.4',
  return_count: 0,
  returned_quantity: 0,
  returned_gross: '0.00',
  returned_revenue: '0.00',
  returned_tax: '0.00',
  returned_cost: '0.00',
  returned_margin: '0.00',
  net_quantity: 11,
  net_revenue: '1777.19',
  net_cost: '1220.00',
  net_margin: '557.19',
  net_margin_pct: '31.4',
  contract_profit: '0.00',
  contract_profit_returned: '0.00',
  amount: null,
  refunded: null,
  net_amount: null,
};
const hidden = {
  cost: null,
  margin: null,
  margin_pct: null,
  returned_cost: null,
  returned_margin: null,
  net_cost: null,
  net_margin: null,
  net_margin_pct: null,
  contract_profit: null,
  contract_profit_returned: null,
};
const report = {
  from: '2026-09-01',
  to: '2026-10-31',
  group_by: 'month',
  filters: {
    branch_id: null,
    employee_id: null,
    category_id: null,
    category_level: null,
    product_id: null,
    sale_type: null,
  },
  sort: 'key_asc',
  generated_at: ts,
  can_see_cost: true,
  rows: [{ key: '2026-09-01', label: '2026-09', label_en: null, sub_label: null, ...measures }],
  totals: measures,
  check: {
    rows_match: true,
    differences: {
      revenue: '0.00',
      tax: '0.00',
      cost: '0.00',
      returned_revenue: '0.00',
      gross: '0.00',
      returned_gross: '0.00',
    },
  },
  total_count: 1,
  page: 1,
  page_size: 50,
};
const query = { from: '2026-09-01', to: '2026-10-31', group_by: 'month' };

describe('D02 sales report contract', () => {
  it('parses a query and fills the defaults; query strings are coerced', () => {
    const q = SalesReportQuery.parse({ ...query, page: '2', page_size: '1000' });
    expect(q).toMatchObject({ category_level: 'leaf', page: 2, page_size: 1000 });
    expect(SalesReportQuery.parse(query)).toMatchObject({ page: 1, page_size: 50 });
    for (const g of SALES_REPORT_GROUP_BY) {
      expect(SalesReportQuery.safeParse({ ...query, group_by: g }).success).toBe(true);
    }
  });

  it('refuses a bad period: from after to, more than 366 days, a non-date', () => {
    expect(SalesReportQuery.safeParse({ ...query, from: '2026-11-01' }).success).toBe(false);
    expect(SalesReportQuery.safeParse({ ...query, from: '2025-10-31' }).success).toBe(true); // 366 days
    expect(SalesReportQuery.safeParse({ ...query, from: '2025-10-30' }).success).toBe(false); // 367
    expect(SalesReportQuery.safeParse({ ...query, to: '2026-02-30' }).success).toBe(false);
    expect(SalesReportQuery.safeParse({ group_by: 'month' }).success).toBe(false);
    expect(salesReportDays('2026-09-01', '2026-09-01')).toBe(1);
    expect(salesReportDays('2025-10-31', '2026-10-31')).toBe(366);
  });

  it('refuses unknown fields (an organization id), bad ids, grouping, sort and page size', () => {
    expect(SalesReportQuery.safeParse({ ...query, organization_id: ID }).success).toBe(false);
    expect(SalesReportQuery.safeParse({ ...query, branch_id: 'x' }).success).toBe(false);
    expect(SalesReportQuery.safeParse({ ...query, group_by: 'colour' }).success).toBe(false);
    expect(SalesReportQuery.safeParse({ ...query, sort: 'best' }).success).toBe(false);
    expect(SalesReportQuery.safeParse({ ...query, sale_type: 'layaway' }).success).toBe(false);
    expect(SalesReportQuery.safeParse({ ...query, page_size: 1001 }).success).toBe(false);
    expect(SalesReportQuery.safeParse({ ...query, page: 0 }).success).toBe(false);
    expect(SalesReportQuery.safeParse({ ...query, category_level: 'mid' }).success).toBe(false);
  });

  it('accepts every filter and refuses product / category filters for the payment type grouping', () => {
    const full = {
      ...query,
      branch_id: ID,
      employee_id: ID,
      category_id: ID,
      product_id: ID,
      sale_type: 'installment',
      sort: 'margin_desc',
    };
    expect(SalesReportQuery.safeParse(full).success).toBe(true);
    expect(SalesReportQuery.safeParse({ ...full, group_by: 'payment_type' }).success).toBe(false);
    expect(
      SalesReportQuery.safeParse({
        ...query,
        group_by: 'payment_type',
        employee_id: ID,
        sale_type: 'cash',
      }).success,
    ).toBe(true);
    expect(SALES_REPORT_COST_SORTS).toEqual(['margin_desc', 'margin_asc']);
  });

  it('parses a full report and one without cost (nulls) and a payment-type row', () => {
    expect(SalesReport.parse(report).rows).toHaveLength(1);
    const noCost = {
      ...report,
      can_see_cost: false,
      rows: [{ ...report.rows[0], ...hidden }],
      totals: { ...measures, ...hidden },
      check: { rows_match: true, differences: { ...report.check.differences, cost: null } },
    };
    const parsed = SalesReport.parse(noCost);
    expect(parsed.rows[0]?.margin).toBeNull();
    expect(parsed.totals.revenue).toBe('1777.19');
    const money = {
      key: 'cash',
      label: 'cash',
      label_en: null,
      sub_label: null,
      sales_count: null,
      quantity: null,
      revenue: null,
      gross: null,
      tax: null,
      discount: null,
      cost: null,
      margin: null,
      margin_pct: null,
      return_count: null,
      returned_quantity: null,
      returned_gross: null,
      returned_revenue: null,
      returned_tax: null,
      returned_cost: null,
      returned_margin: null,
      net_quantity: null,
      net_revenue: null,
      net_cost: null,
      net_margin: null,
      net_margin_pct: null,
      contract_profit: null,
      contract_profit_returned: null,
      amount: '2130.00',
      refunded: '100.00',
      net_amount: '2030.00',
    };
    expect(SalesReportRow.parse(money).amount).toBe('2130.00');
  });

  it('keeps money as strings and a negative net; a check can be null; a bad shape is refused', () => {
    const negative = {
      ...measures,
      net_revenue: '-100.00',
      net_margin: '-40.00',
      net_margin_pct: '40.0',
    };
    expect(SalesReport.parse({ ...report, totals: negative }).totals.net_revenue).toBe('-100.00');
    expect(SalesReport.parse({ ...report, check: null }).check).toBeNull();
    expect(
      SalesReport.safeParse({ ...report, totals: { ...measures, revenue: 1777.19 } }).success,
    ).toBe(false);
    expect(
      SalesReport.safeParse({ ...report, totals: { ...measures, revenue: '1,777.19' } }).success,
    ).toBe(false);
    expect(SalesReport.safeParse({ ...report, sort: 'best' }).success).toBe(false);
    expect(SalesReport.safeParse({ ...report, page_size: 1001 }).success).toBe(false);
  });
});

const aging = {
  outstanding: '24000.00',
  principal: '20000.00',
  profit: '4000.00',
  not_due: '22000.00',
  late_1_30: '2000.00',
  late_31_60: '0.00',
  late_61_90: '0.00',
  late_90_plus: '0.00',
  overdue: '2000.00',
  overdue_pct: '8.3',
  contracts: 2,
  customers: 1,
  overdue_contracts: 1,
  max_days_late: 30,
  oldest_due_date: '2026-09-23',
  migrated_contracts: 0,
};
const split = { amount: '0.00', principal: '0.00', profit: '0.00' };
const receivables = {
  as_of: '2026-10-23',
  generated_at: ts,
  group_by: 'customer',
  filters: { branch_id: null, collector_id: 'none', customer_id: null, q: null, min_days: null },
  sort: 'outstanding_desc',
  rows: [
    {
      key: ID,
      label: 'Amal',
      sub_label: '01022220001',
      last_payment_at: ts,
      customer: { id: ID, name: 'Amal', phone: '01022220001' },
      collector: { id: ID, name: 'Collector' },
      ...aging,
    },
    { key: 'none', label: null, sub_label: null, last_payment_at: null, collector: null, ...aging },
  ],
  totals: {
    ...aging,
    buckets: {
      not_due: split,
      late_1_30: split,
      late_31_60: split,
      late_61_90: split,
      late_90_plus: split,
    },
  },
  check: {
    rows_match: true,
    contracts_checked: 2,
    contracts_without_schedule: 0,
    differences: {
      outstanding: '0.00',
      principal: '0.00',
      not_due: '0.00',
      late_1_30: '0.00',
      late_31_60: '0.00',
      late_61_90: '0.00',
      late_90_plus: '0.00',
    },
  },
  total_count: 2,
  page: 1,
  page_size: 50,
};

describe('D03 receivables aging contract', () => {
  it('has four groupings and five buckets', () => {
    expect(RECEIVABLES_GROUP_BY).toEqual(['customer', 'branch', 'collector', 'contract']);
    expect(RECEIVABLES_BUCKETS).toEqual([
      'not_due',
      'late_1_30',
      'late_31_60',
      'late_61_90',
      'late_90_plus',
    ]);
  });

  it('parses a query, fills the defaults and coerces query strings', () => {
    expect(ReceivablesQuery.parse({ group_by: 'branch' })).toEqual({
      group_by: 'branch',
      page: 1,
      page_size: 50,
    });
    expect(
      ReceivablesQuery.parse({
        group_by: 'customer',
        min_days: '61',
        q: ' amal ',
        page_size: '1000',
      }),
    ).toMatchObject({ min_days: 61, q: 'amal', page_size: 1000 });
  });

  it('accepts a collector id or none, and nothing else', () => {
    expect(ReceivablesQuery.safeParse({ group_by: 'customer', collector_id: ID }).success).toBe(
      true,
    );
    expect(ReceivablesQuery.safeParse({ group_by: 'customer', collector_id: 'none' }).success).toBe(
      true,
    );
    expect(ReceivablesQuery.safeParse({ group_by: 'customer', collector_id: 'all' }).success).toBe(
      false,
    );
  });

  it('allows a search only with the customer or contract grouping, at most 100 characters', () => {
    expect(ReceivablesQuery.safeParse({ group_by: 'contract', q: 'K-1' }).success).toBe(true);
    expect(ReceivablesQuery.safeParse({ group_by: 'branch', q: 'K-1' }).success).toBe(false);
    expect(ReceivablesQuery.safeParse({ group_by: 'customer', q: 'x'.repeat(101) }).success).toBe(
      false,
    );
  });

  it('refuses unknown fields (an organization id), a bad grouping, sort, min_days and page size', () => {
    for (const bad of [
      { group_by: 'customer', organization_id: ID },
      { group_by: 'product' },
      { group_by: 'customer', sort: 'profit_desc' },
      { group_by: 'customer', min_days: 0 },
      { group_by: 'customer', page_size: 1001 },
      { group_by: 'customer', branch_id: 'x' },
    ]) {
      expect(ReceivablesQuery.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it('parses a report with rows of every shape, a null overdue %, and refuses money as a number', () => {
    expect(ReceivablesReport.parse(receivables).rows).toHaveLength(2);
    expect(
      ReceivablesRow.parse({
        ...aging,
        key: ID,
        label: 'K-000001',
        sub_label: 'Amal',
        last_payment_at: null,
        overdue_pct: null,
        max_days_late: null,
        customer: { id: ID, name: 'Amal', phone: null },
        branch: { id: ID, name: 'Main', code: null },
        contract: {
          id: ID,
          number: 'K-000001',
          frequency: 'monthly',
          status: 'rescheduled',
          is_migrated: true,
          next_due_date: '2026-11-01',
        },
      }).contract?.is_migrated,
    ).toBe(true);
    expect(
      ReceivablesReport.safeParse({
        ...receivables,
        totals: { ...receivables.totals, outstanding: 24000 },
      }).success,
    ).toBe(false);
  });
});
