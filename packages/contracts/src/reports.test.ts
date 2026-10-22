import { describe, expect, it } from 'vitest';
import {
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
