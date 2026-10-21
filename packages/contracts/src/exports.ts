import { z } from 'zod';
import { IsoTimestamp, Money, Uuid } from './common.js';

/**
 * M03 full export (D86). The owner (or anyone holding `export.data`) asks for every table of the
 * shop as one zip of CSV and JSON files; a background job builds it in one database snapshot and
 * the download is F14's signed link. The zip carries a manifest with row counts and control totals
 * so it can be restored into a clean environment and checked (Q04). `export.data` works in an
 * expired shop; a suspended shop can't export. Money and quantities are decimal strings.
 */

/** Hard limits of one export, and the pause between two (decision 9). */
export const EXPORT_LIMITS = {
  /** Uncompressed size of all files in the zip. */
  maxBytes: 500 * 1024 * 1024,
  maxRows: 2_000_000,
  /** One export per shop per hour after a completed one. */
  minSecondsBetween: 3600,
  /** The zip is removed from storage after this many days. */
  keepDays: 7,
  /** Rows read from the database per page. */
  pageRows: 2000,
} as const;

/** `queued` until the worker picks the job up, then `running`. */
export const EXPORT_STATUSES = ['queued', 'running', 'completed', 'failed', 'cancelled'] as const;
export const ExportStatus = z.enum(EXPORT_STATUSES);
export type ExportStatus = z.infer<typeof ExportStatus>;

/** `full` writes national IDs as they are stored and needs `customer.view_pii` on top of `export.data`. */
export const EXPORT_PII_MODES = ['masked', 'full'] as const;
export const ExportPiiMode = z.enum(EXPORT_PII_MODES);
export type ExportPiiMode = z.infer<typeof ExportPiiMode>;

/** `POST /api/exports` (Idempotency-Key header). */
export const StartExportBody = z.object({ pii: ExportPiiMode.default('masked') }).strict();
export type StartExportBody = z.infer<typeof StartExportBody>;

export const ExportIdParams = z.object({ id: Uuid }).strict();
export type ExportIdParams = z.infer<typeof ExportIdParams>;

/** Why an export failed, as a code the screen turns into words. */
export const EXPORT_FAILURE_CODES = [
  'EXPORT_TOO_LARGE',
  'EXPORT_PERMISSION_LOST',
  'EXPORT_SHOP_NOT_ACTIVE',
  'EXPORT_FAILED',
] as const;
export const ExportFailureCode = z.enum(EXPORT_FAILURE_CODES);
export type ExportFailureCode = z.infer<typeof ExportFailureCode>;

export const ExportRequester = z.object({ id: Uuid, name: z.string() });
export type ExportRequester = z.infer<typeof ExportRequester>;

/** One export as the API answers it. */
export const ExportJob = z.object({
  id: Uuid,
  status: ExportStatus,
  requested_by: ExportRequester.nullable(),
  requested_at: IsoTimestamp,
  finished_at: IsoTimestamp.nullable(),
  pii: ExportPiiMode,
  /** Rows in all tables (0 until the export is completed). */
  rows: z.number().int().min(0),
  size_bytes: z.number().int().min(0).nullable(),
  /** The zip in F14 while the file is kept (7 days); null before that and after the cleanup. */
  file_id: Uuid.nullable(),
  file_name: z.string().nullable(),
  /** Set when the cleanup removed the zip. */
  file_removed_at: IsoTimestamp.nullable(),
  error_code: ExportFailureCode.nullable(),
});
export type ExportJob = z.infer<typeof ExportJob>;

export const ExportListResponse = z.object({ items: z.array(ExportJob) });
export type ExportListResponse = z.infer<typeof ExportListResponse>;

// ---------------------------------------------------------------------------------------------
// The manifest inside the zip (the restore check parses it with this schema)

export const EXPORT_MANIFEST_FORMAT_VERSION = 1;

export const ExportManifestTable = z.object({
  name: z.string().min(1),
  rows: z.number().int().min(0),
  /** Column names in table order, as in the first line of the CSV. */
  columns: z.array(z.string().min(1)).min(1),
});
export type ExportManifestTable = z.infer<typeof ExportManifestTable>;

/** Control totals computed by the database in the same snapshot as the rows. */
export const ExportManifestTotals = z.object({
  cash_balance_total: Money,
  stock_on_hand_total: z.string().regex(/^-?\d+$/),
  store_credit_total: Money,
  open_contracts_remaining: Money,
  sales_total: Money,
  payments_in_total: Money,
  payments_out_total: Money,
  audit_rows: z.number().int().min(0),
});
export type ExportManifestTotals = z.infer<typeof ExportManifestTotals>;

export const ExportManifest = z.object({
  format_version: z.literal(EXPORT_MANIFEST_FORMAT_VERSION),
  shop: z.object({ id: Uuid, name: z.string(), tenant_slug: z.string() }),
  exported_at: IsoTimestamp,
  requested_by: ExportRequester.nullable(),
  pii: ExportPiiMode,
  schema: z.object({ migration: z.string(), contracts_version: z.string() }),
  tables: z.array(ExportManifestTable).min(1),
  totals: ExportManifestTotals,
});
export type ExportManifest = z.infer<typeof ExportManifest>;

// ---------------------------------------------------------------------------------------------
// Error details

/** EXPORT_RUNNING (409): the export that is already queued or running. */
export const ExportRunningDetail = z.object({ job_id: Uuid });
export type ExportRunningDetail = z.infer<typeof ExportRunningDetail>;

/** EXPORT_TOO_SOON (429): seconds until the next export may start. */
export const ExportTooSoonDetail = z.object({ retry_after: z.number().int().min(1) });
export type ExportTooSoonDetail = z.infer<typeof ExportTooSoonDetail>;
