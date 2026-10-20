// server/src/services/imports.service.ts
//
// M01 import (D83). Node reads the uploaded file and turns it into plain rows; SQL decides
// everything else (public.create_import checks every row, public.jobs_import_apply writes them).
//
// A call: session + shop + permission (route) -> the file (shop-scoped read, purpose `import`) ->
// bytes from storage (service role, own-shop path only) -> parse (limits, type from the bytes) ->
// header mapping -> rows -> SQL. A failed dry run also writes the errors as a CSV file
// (purpose export) linked to the job.

import { randomUUID } from 'node:crypto';
import {
  ImportInspection,
  ImportJob,
  ImportListResponse,
  missingImportColumns,
  suggestImportMapping,
  IMPORT_PREVIEW_ROWS,
  type CreateImportBody,
  type ImportKind,
  type ImportListQuery,
  type ImportMapping,
  type InspectImportBody,
  type RunImportBody,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { AppError, mapDbError, safeMessage, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';
import { assertOwnPath, tenantFilePath } from '../utils/tenant';
import { sha256Hex } from './files.rules';
import { buildErrorsCsv } from './imports/files';
import { readImportTable, toFieldRows, unusedHeaders, type FileTable } from './imports/parse';
import * as storage from './storage.service';

function fail(error: unknown, what: string): never {
  const mapped = mapDbError(error);
  if (mapped) throw mapped;
  logger.error({ err: error }, `${what} failed`);
  throw ServerError('Request failed.');
}

const notFound = () => new AppError(safeMessage('FILE_NOT_FOUND'), 'FILE_NOT_FOUND');

/** The bytes of one of the caller's import files. Another shop's id reads as "not found". */
export async function loadImportFile(ctx: RequestContext, fileId: string): Promise<Buffer> {
  // RLS limits the row to the caller's shop.
  const { data, error } = await ctx.db
    .from('files')
    .select('id, purpose, path, sha256')
    .eq('id', fileId)
    .maybeSingle();
  if (error) fail(error, 'files read for import');
  if (data === null || data.purpose !== 'import') throw notFound();
  const bytes = await storage.getObject(assertOwnPath(ctx, data.path));
  // The stored object must be the file that was uploaded.
  if (data.sha256 !== null && data.sha256.trim() !== sha256Hex(bytes)) {
    logger.error({ fileId }, 'import file does not match its recorded hash');
    throw new AppError(safeMessage('IMPORT_FILE_UNREADABLE'), 'IMPORT_FILE_UNREADABLE');
  }
  return bytes;
}

/** The mapping to use: the caller's explicit one, else the automatic match of the headers. */
export function resolveMapping(
  kind: ImportKind,
  table: FileTable,
  explicit: ImportMapping | undefined,
): ImportMapping {
  let mapping: ImportMapping;
  if (explicit === undefined) {
    mapping = suggestImportMapping(kind, table.headers).mapping;
  } else {
    const headers = new Set(table.headers);
    const used = new Set<string>();
    for (const header of Object.values(explicit)) {
      if (!headers.has(header) || used.has(header)) {
        throw new AppError(safeMessage('IMPORT_MAPPING_INVALID'), 'IMPORT_MAPPING_INVALID');
      }
      used.add(header);
    }
    mapping = explicit;
  }
  const missing = missingImportColumns(kind, Object.keys(mapping));
  if (missing.length > 0) {
    throw new AppError(safeMessage('IMPORT_MISSING_COLUMNS'), 'IMPORT_MISSING_COLUMNS', undefined, {
      columns: missing,
      headers: table.headers,
    });
  }
  return mapping;
}

/** POST /api/imports/inspect: what is in the file, and how its headers would be matched. Saves nothing. */
export async function inspectImport(
  ctx: RequestContext,
  body: InspectImportBody,
): Promise<ImportInspection> {
  const bytes = await loadImportFile(ctx, body.file_id);
  const table = await readImportTable(bytes, { sheet: body.sheet });
  const sample = table.rows.slice(0, IMPORT_PREVIEW_ROWS).map((row) => {
    const record: Record<string, string> = {};
    table.headers.forEach((h, i) => {
      if (h !== '' && record[h] === undefined) record[h] = row.cells[i] ?? '';
    });
    return record;
  });
  return ImportInspection.parse({
    kind: body.kind,
    file_type: table.fileType,
    sheets: table.sheets,
    sheet: table.sheet,
    headers: table.headers,
    total_rows: table.rows.length,
    sample,
    suggestion: suggestImportMapping(body.kind, table.headers),
  });
}

/** POST /api/imports: the dry run. A failed one gets its errors CSV. */
export async function createImport(
  ctx: RequestContext,
  body: CreateImportBody,
): Promise<ImportJob> {
  const bytes = await loadImportFile(ctx, body.file_id);
  const table = await readImportTable(bytes, { sheet: body.sheet });
  const mapping = resolveMapping(body.kind, table, body.mapping);
  const rows = toFieldRows(body.kind, table, mapping);
  if (rows.length === 0) {
    throw new AppError(safeMessage('IMPORT_FILE_UNREADABLE'), 'IMPORT_FILE_UNREADABLE');
  }
  const { data, error } = await ctx.db.rpc('create_import', {
    p_kind: body.kind,
    p_file_id: body.file_id,
    p_branch_id: body.branch_id ?? null,
    p_rows: rows as unknown as Json,
    p_meta: {
      sheet: table.sheet,
      mapping,
      unmapped_headers: unusedHeaders(table, mapping),
    } as Json,
    p_idempotency_key: body.idempotency_key,
  });
  if (error) fail(error, 'create_import');
  const job = ImportJob.parse(data);
  if (job.status === 'failed' && job.result_file_id === null && job.report.errors.length > 0) {
    return attachErrorsFile(ctx, job);
  }
  return job;
}

/** The report's errors as a CSV file linked to the job. If that fails the job is still returned. */
async function attachErrorsFile(ctx: RequestContext, job: ImportJob): Promise<ImportJob> {
  const csv = buildErrorsCsv(job.report.errors);
  const id = randomUUID();
  const now = new Date();
  const path = tenantFilePath(
    ctx,
    'export',
    String(now.getUTCFullYear()),
    String(now.getUTCMonth() + 1).padStart(2, '0'),
    `${id}.csv`,
  );
  try {
    await storage.putObject(path, csv, 'text/csv');
  } catch (e) {
    logger.error({ err: e, jobId: job.id }, 'import errors file could not be stored');
    return job;
  }
  const { data, error } = await ctx.db.rpc('attach_import_result', {
    p_job_id: job.id,
    p_file_id: id,
    p_path: path,
    p_original_name: `import-errors-${job.id.slice(0, 8)}.csv`,
    p_mime: 'text/csv',
    p_size_bytes: csv.length,
    p_sha256: sha256Hex(csv),
  });
  if (error) {
    await storage.removeObject(path);
    logger.error({ err: error, jobId: job.id }, 'attach_import_result failed');
    return job;
  }
  return ImportJob.parse(data);
}

export async function listImports(
  ctx: RequestContext,
  query: ImportListQuery,
): Promise<ImportListResponse> {
  const { data, error } = await ctx.db.rpc('list_import_jobs', {
    p_filters: {
      ...(query.kind ? { kind: query.kind } : {}),
      ...(query.status ? { status: query.status } : {}),
      limit: query.limit,
      ...(query.cursor ? { cursor: query.cursor } : {}),
    },
  });
  if (error) fail(error, 'list_import_jobs');
  return ImportListResponse.parse(data);
}

export async function getImport(ctx: RequestContext, id: string): Promise<ImportJob> {
  const { data, error } = await ctx.db.rpc('get_import_job', { p_id: id });
  if (error) fail(error, 'get_import_job');
  return ImportJob.parse(data);
}

/** POST /api/imports/:id/run: queues the background import ('importing'); the same key again is a no-op. */
export async function runImport(
  ctx: RequestContext,
  id: string,
  body: RunImportBody,
): Promise<ImportJob> {
  const { data, error } = await ctx.db.rpc('queue_import', {
    p_id: id,
    p_idempotency_key: body.idempotency_key,
  });
  if (error) fail(error, 'queue_import');
  return ImportJob.parse(data);
}

export async function cancelImport(ctx: RequestContext, id: string): Promise<ImportJob> {
  const { data, error } = await ctx.db.rpc('cancel_import_job', { p_id: id });
  if (error) fail(error, 'cancel_import_job');
  return ImportJob.parse(data);
}
