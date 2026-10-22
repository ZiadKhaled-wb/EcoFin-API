import { describe, it, expect } from 'vitest';
import { SalesReportQuery } from '@ziadkhaled-wb/contracts';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { getSalesReport } from './reports.service';

const ID = 'a0200000-0000-4000-8000-000000000002';
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
// The totals differ from the sum of the rows on purpose: the service must forward them, not add.
const answer = {
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
  rows: [
    { key: '2026-09-01', label: '2026-09', label_en: null, sub_label: null, ...measures },
    { key: '2026-10-01', label: '2026-10', label_en: null, sub_label: null, ...measures },
  ],
  totals: { ...measures, revenue: '9999.99' },
  check: {
    rows_match: false,
    differences: {
      revenue: '-6445.61',
      tax: '0.00',
      cost: '0.00',
      returned_revenue: '0.00',
      gross: '0.00',
      returned_gross: '0.00',
    },
  },
  total_count: 2,
  page: 1,
  page_size: 50,
};
const query = SalesReportQuery.parse({ from: '2026-09-01', to: '2026-10-31', group_by: 'month' });

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'OWNER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('D02 sales report service', () => {
  it('passes the period, grouping and paging; no filter argument when none is set', async () => {
    const { db, ctx } = setup();
    db.queue({ data: answer, error: null });
    await getSalesReport(ctx, query);
    expect(db.rpc).toHaveBeenCalledWith('report_sales', {
      p_from: '2026-09-01',
      p_to: '2026-10-31',
      p_group_by: 'month',
      p_category_level: 'leaf',
      p_page: 1,
      p_page_size: 50,
    });
  });

  it('passes every filter and the sort', async () => {
    const { db, ctx } = setup();
    db.queue({ data: answer, error: null });
    await getSalesReport(
      ctx,
      SalesReportQuery.parse({
        from: '2026-09-01',
        to: '2026-10-31',
        group_by: 'category',
        category_level: 'top',
        branch_id: ID,
        employee_id: ID,
        category_id: ID,
        product_id: ID,
        sale_type: 'installment',
        sort: 'margin_desc',
        page: '2',
        page_size: '1000',
      }),
    );
    expect(db.rpc).toHaveBeenCalledWith('report_sales', {
      p_from: '2026-09-01',
      p_to: '2026-10-31',
      p_group_by: 'category',
      p_category_level: 'top',
      p_page: 2,
      p_page_size: 1000,
      p_branch_id: ID,
      p_employee_id: ID,
      p_category_id: ID,
      p_product_id: ID,
      p_sale_type: 'installment',
      p_sort: 'margin_desc',
    });
  });

  it('computes nothing: the totals and the check are the database answer, even when they disagree with the rows', async () => {
    const { db, ctx } = setup();
    db.queue({ data: answer, error: null });
    const out = await getSalesReport(ctx, query);
    expect(out.totals.revenue).toBe('9999.99');
    expect(out.rows.map((r) => r.revenue)).toEqual(['1777.19', '1777.19']);
    expect(out.check).toEqual(answer.check);
    expect(out.total_count).toBe(2);
  });

  it('maps the database errors to their codes', async () => {
    const { db, ctx } = setup();
    const cases: [string, string, string, number][] = [
      ['BRANCH_NOT_FOUND', 'P0001', 'BRANCH_NOT_FOUND', 404],
      [`BRANCH_DENIED: ${ID}`, '42501', 'BRANCH_DENIED', 403],
      ['EMPLOYEE_NOT_FOUND', 'P0001', 'EMPLOYEE_NOT_FOUND', 404],
      ['CATEGORY_NOT_FOUND', 'P0001', 'CATEGORY_NOT_FOUND', 404],
      ['PRODUCT_NOT_FOUND', 'P0001', 'PRODUCT_NOT_FOUND', 404],
      ['PERMISSION_DENIED: report.view', '42501', 'PERMISSION_DENIED', 403],
      [
        'VALIDATION_FAILED: sort (margin needs report.financial)',
        'P0001',
        'VALIDATION_FAILED',
        400,
      ],
    ];
    for (const [message, dbCode, code, status] of cases) {
      db.queue({ data: null, error: { message, code: dbCode } });
      await expect(getSalesReport(ctx, query)).rejects.toMatchObject({ code, statusCode: status });
    }
  });

  it('refuses an answer that does not match the contract (money must be a string)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { ...answer, totals: { ...measures, revenue: 1777.19 } }, error: null });
    await expect(getSalesReport(ctx, query)).rejects.toThrow();
  });

  it('hides a database failure behind a generic error', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'relation "x" does not exist', code: '42P01' } });
    await expect(getSalesReport(ctx, query)).rejects.toMatchObject({ statusCode: 500 });
  });
});
