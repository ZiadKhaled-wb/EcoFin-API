import { ExportJob, ExportListResponse, type StartExportBody } from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// M03 (D86). Every rule lives in SQL (20261027090000_m03_full_export.sql): the API shapes the calls.
// The work itself is the background job 'export.full' (src/jobs/handlers/exportFull.ts); the
// download is F14's signed link (GET /api/files/:id/url, purpose export, export.data).

function fail(error: unknown, what: string): never {
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code }, what }, 'exports database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** POST /api/exports: queues the export; the same key again answers the same job. */
export async function startExport(
  ctx: RequestContext,
  body: StartExportBody,
  idempotencyKey: string,
): Promise<ExportJob> {
  const { data, error } = await ctx.db.rpc('start_full_export', {
    p_body: body,
    p_idempotency_key: idempotencyKey,
  });
  if (error) fail(error, 'start_full_export');
  return ExportJob.parse(data);
}

export async function listExports(ctx: RequestContext): Promise<ExportListResponse> {
  const { data, error } = await ctx.db.rpc('list_exports');
  if (error) fail(error, 'list_exports');
  return ExportListResponse.parse(data);
}

export async function getExport(ctx: RequestContext, id: string): Promise<ExportJob> {
  const { data, error } = await ctx.db.rpc('get_export', { p_id: id });
  if (error) fail(error, 'get_export');
  return ExportJob.parse(data);
}

export async function cancelExport(ctx: RequestContext, id: string): Promise<ExportJob> {
  const { data, error } = await ctx.db.rpc('cancel_export', { p_id: id });
  if (error) fail(error, 'cancel_export');
  return ExportJob.parse(data);
}
