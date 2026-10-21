import { describe, expect, it } from 'vitest';
import {
  EXPORT_LIMITS,
  ExportJob,
  ExportListResponse,
  ExportManifest,
  ExportRunningDetail,
  ExportTooSoonDetail,
  StartExportBody,
} from './exports.js';
import { errorCodeHttpStatus } from './errors.js';

const ID = 'a0f00000-0000-4000-8000-000000000001';
const ID2 = 'a0f00000-0000-4000-8000-000000000002';
const ts = '2026-10-22T10:00:00.000Z';

const job = {
  id: ID,
  status: 'completed',
  requested_by: { id: ID2, name: 'Owner' },
  requested_at: ts,
  finished_at: ts,
  pii: 'masked',
  rows: 120,
  size_bytes: 2048,
  file_id: ID2,
  file_name: 'ecofin-export-shop-20261022-1000.zip',
  file_removed_at: null,
  error_code: null,
};

const manifest = {
  format_version: 1,
  shop: { id: ID, name: 'Shop', tenant_slug: 'shop' },
  exported_at: ts,
  requested_by: null,
  pii: 'masked',
  schema: { migration: '20261027090000_m03_full_export', contracts_version: '0.56.0' },
  tables: [{ name: 'customers', rows: 2, columns: ['id', 'full_name'] }],
  totals: {
    cash_balance_total: '10.50',
    stock_on_hand_total: '-3',
    store_credit_total: '0.00',
    open_contracts_remaining: '1200.00',
    sales_total: '0.00',
    payments_in_total: '0.00',
    payments_out_total: '0.00',
    audit_rows: 4,
  },
};

describe('M03 export contracts', () => {
  it('starts masked by default, accepts full, refuses anything else (strict)', () => {
    expect(StartExportBody.parse({}).pii).toBe('masked');
    expect(StartExportBody.parse({ pii: 'full' }).pii).toBe('full');
    expect(StartExportBody.safeParse({ pii: 'raw' }).success).toBe(false);
    expect(StartExportBody.safeParse({ organization_id: ID }).success).toBe(false);
  });

  it('the job answer: every status, file_id only while the file is kept', () => {
    expect(ExportJob.parse(job).file_id).toBe(ID2);
    for (const status of ['queued', 'running', 'completed', 'failed', 'cancelled']) {
      expect(ExportJob.safeParse({ ...job, status }).success).toBe(true);
    }
    expect(ExportJob.safeParse({ ...job, status: 'importing' }).success).toBe(false);
    expect(ExportJob.parse({ ...job, file_id: null, file_removed_at: ts }).file_id).toBeNull();
    expect(
      ExportJob.parse({ ...job, status: 'failed', error_code: 'EXPORT_TOO_LARGE' }).error_code,
    ).toBe('EXPORT_TOO_LARGE');
    expect(ExportJob.safeParse({ ...job, error_code: 'boom' }).success).toBe(false);
    expect(ExportListResponse.parse({ items: [job] }).items).toHaveLength(1);
  });

  it('the manifest: tables with columns, text totals, a format version', () => {
    expect(ExportManifest.parse(manifest).tables[0]?.rows).toBe(2);
    expect(ExportManifest.safeParse({ ...manifest, format_version: 2 }).success).toBe(false);
    expect(ExportManifest.safeParse({ ...manifest, tables: [] }).success).toBe(false);
    expect(
      ExportManifest.safeParse({
        ...manifest,
        totals: { ...manifest.totals, cash_balance_total: 10.5 },
      }).success,
    ).toBe(false);
    expect(
      ExportManifest.safeParse({
        ...manifest,
        totals: { ...manifest.totals, stock_on_hand_total: '3.5' },
      }).success,
    ).toBe(false);
  });

  it('error details and HTTP statuses', () => {
    expect(ExportRunningDetail.parse({ job_id: ID }).job_id).toBe(ID);
    expect(ExportTooSoonDetail.parse({ retry_after: 120 }).retry_after).toBe(120);
    expect(ExportTooSoonDetail.safeParse({ retry_after: 0 }).success).toBe(false);
    expect(errorCodeHttpStatus.EXPORT_RUNNING).toBe(409);
    expect(errorCodeHttpStatus.EXPORT_TOO_SOON).toBe(429);
    expect(errorCodeHttpStatus.EXPORT_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.EXPORT_TOO_LARGE).toBe(422);
  });

  it('the limits are the ones of the spec', () => {
    expect(EXPORT_LIMITS.maxBytes).toBe(500 * 1024 * 1024);
    expect(EXPORT_LIMITS.maxRows).toBe(2_000_000);
    expect(EXPORT_LIMITS.minSecondsBetween).toBe(3600);
    expect(EXPORT_LIMITS.keepDays).toBe(7);
  });
});
