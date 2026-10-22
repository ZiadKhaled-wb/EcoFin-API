import { SalesReport, type SalesReportQuery } from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// D02 (D89). The sales and margin report: every number is a SQL aggregate computed by
// public.report_sales (20261030090000_d02_sales_report.sql); the API passes the query through and
// parses the answer. Nothing is added, rounded or sorted here.

function fail(error: unknown): never {
  // The message and the Postgres code only: amounts are never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'reports database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** GET /api/reports/sales: the report for a period, grouped and filtered as the query says. */
export async function getSalesReport(
  ctx: RequestContext,
  query: SalesReportQuery,
): Promise<SalesReport> {
  const { data, error } = await ctx.db.rpc('report_sales', {
    p_from: query.from,
    p_to: query.to,
    p_group_by: query.group_by,
    p_category_level: query.category_level,
    p_page: query.page,
    p_page_size: query.page_size,
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.employee_id ? { p_employee_id: query.employee_id } : {}),
    ...(query.category_id ? { p_category_id: query.category_id } : {}),
    ...(query.product_id ? { p_product_id: query.product_id } : {}),
    ...(query.sale_type ? { p_sale_type: query.sale_type } : {}),
    ...(query.sort ? { p_sort: query.sort } : {}),
  });
  if (error) fail(error);
  return SalesReport.parse(data);
}
