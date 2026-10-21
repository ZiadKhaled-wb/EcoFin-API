import {
  MigrationBatchReversal,
  MigrationReport,
  MigrationSignOff,
  MigrationSignOffList,
  type MigrationReportQuery,
  type MigrationSignOffBody,
  type ReverseMigrationBatchBody,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';
import { csv, type BuiltFile } from './imports/files';

// M02 (D85). The reconciliation report, the sign-off and the reversal of a migration batch: every
// number and every rule lives in SQL (20261026090000_m02_opening_balances.sql). The API shapes the
// calls and writes the CSV of the report.

function fail(error: unknown): never {
  // The message and the Postgres code only: amounts, notes and reasons are never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'migration database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** GET /api/migration/report (json) */
export async function getReport(
  ctx: RequestContext,
  query: Pick<MigrationReportQuery, 'batch_id' | 'branch_id' | 'customer_id'>,
): Promise<MigrationReport> {
  const filters = {
    ...(query.batch_id ? { batch_id: query.batch_id } : {}),
    ...(query.branch_id ? { branch_id: query.branch_id } : {}),
    ...(query.customer_id ? { customer_id: query.customer_id } : {}),
  };
  const { data, error } = await ctx.db.rpc('get_migration_report', { p_filters: filters });
  if (error) fail(error);
  return MigrationReport.parse(data);
}

/**
 * The same report as a CSV the owner prints and signs: the totals, then one row per customer, then
 * the cash accounts. UTF-8 with a BOM; a cell that could be read as a formula is quoted (M01's
 * writer). Amounts are the server's decimal strings.
 */
export function buildReportCsv(report: MigrationReport, today: string): BuiltFile {
  const t = report.totals;
  const header = [
    'name',
    'national_id',
    'contracts',
    'original_total',
    'paid_before',
    'imported_total',
    'open_now',
    'overdue_now',
    'collected_since',
  ];
  const rows: string[][] = [
    ['Migration reconciliation report', `as of ${report.as_of}`],
    [],
    header,
    ...report.customers.map((c) => [
      c.name,
      c.national_id ?? '',
      String(c.contracts),
      c.original_total,
      c.paid_before,
      c.imported_total,
      c.open_now,
      c.overdue_now,
      c.collected_since,
    ]),
    [
      'TOTAL',
      '',
      String(t.contracts),
      t.original_total,
      t.paid_before,
      t.imported_total,
      t.open_now,
      t.overdue_now,
      t.collected_since,
    ],
    [],
    ['cash account', 'kind', 'branch', 'opening_posted', 'balance_now'],
    ...report.cash.map((a) => [
      a.name,
      a.kind,
      a.branch_name ?? '',
      a.opening_posted,
      a.balance_now,
    ]),
    ['TOTAL', '', '', report.cash_totals.opening_posted, report.cash_totals.balance_now],
  ];
  return {
    filename: `migration-report-${today}.csv`,
    contentType: 'text/csv; charset=utf-8',
    body: csv(rows),
  };
}

/** POST /api/migration/sign-offs */
export async function signOff(
  ctx: RequestContext,
  body: MigrationSignOffBody,
): Promise<MigrationSignOff> {
  const { data, error } = await ctx.db.rpc('sign_off_migration', { p_body: body });
  if (error) fail(error);
  return MigrationSignOff.parse(data);
}

/** GET /api/migration/sign-offs */
export async function listSignOffs(ctx: RequestContext): Promise<MigrationSignOffList> {
  const { data, error } = await ctx.db.rpc('list_migration_signoffs');
  if (error) fail(error);
  return MigrationSignOffList.parse(data);
}

/** POST /api/migration/batches/:id/reverse */
export async function reverseBatch(
  ctx: RequestContext,
  id: string,
  body: ReverseMigrationBatchBody,
): Promise<MigrationBatchReversal> {
  const { data, error } = await ctx.db.rpc('reverse_migration_batch', {
    p_id: id,
    p_reason: body.reason,
  });
  if (error) fail(error);
  return MigrationBatchReversal.parse(data);
}
