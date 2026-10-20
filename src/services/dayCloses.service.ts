import {
  DayClose,
  DayCloseAlerts,
  DayCloseListResponse,
  DayClosePreview,
  type CloseDayBody,
  type DayCloseListQuery,
  type DayClosePreviewQuery,
  type ReopenDayBody,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// K04 (D84). Day close and reconciliation: every number, check and write lives in SQL
// (20261025090000_k04_day_close.sql). The close and the reopen are one transaction each under the
// day lock; the API only shapes the calls. The preview's hash goes back unchanged to the close.

function fail(error: unknown): never {
  // The message and the Postgres code only: amounts, notes and reasons are never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'day close database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** GET /api/day-closes */
export async function listDayCloses(
  ctx: RequestContext,
  query: DayCloseListQuery,
): Promise<DayCloseListResponse> {
  const { data, error } = await ctx.db.rpc('list_day_closes', {
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    ...(query.status ? { p_status: query.status } : {}),
  });
  if (error) fail(error);
  return DayCloseListResponse.parse(data);
}

/** GET /api/day-closes/preview: the live numbers of an open or reopened day. */
export async function getPreview(
  ctx: RequestContext,
  query: DayClosePreviewQuery,
): Promise<DayClosePreview> {
  const { data, error } = await ctx.db.rpc('get_day_close_preview', {
    p_branch_id: query.branch_id,
    p_business_date: query.date,
  });
  if (error) fail(error);
  return DayClosePreview.parse(data);
}

/** GET /api/day-closes/alerts: the dashboard card. */
export async function getAlerts(ctx: RequestContext): Promise<DayCloseAlerts> {
  const { data, error } = await ctx.db.rpc('day_close_alerts');
  if (error) fail(error);
  return DayCloseAlerts.parse(data);
}

/** GET /api/day-closes/:id: the stored close, with drift against the live numbers. */
export async function getDayClose(ctx: RequestContext, id: string): Promise<DayClose> {
  const { data, error } = await ctx.db.rpc('get_day_close', { p_id: id });
  if (error) fail(error);
  return DayClose.parse(data);
}

/** POST /api/day-closes */
export async function closeDay(ctx: RequestContext, body: CloseDayBody): Promise<DayClose> {
  const note = body.note?.trim() ? body.note.trim() : undefined;
  const { data, error } = await ctx.db.rpc('close_day', {
    p_branch_id: body.branch_id,
    p_business_date: body.business_date,
    p_preview_hash: body.preview_hash,
    ...(note ? { p_note: note } : {}),
  });
  if (error) fail(error);
  return DayClose.parse(data);
}

/** POST /api/day-closes/:id/reopen (day.reopen). */
export async function reopenDay(
  ctx: RequestContext,
  id: string,
  body: ReopenDayBody,
): Promise<DayClose> {
  const { data, error } = await ctx.db.rpc('reopen_day', { p_id: id, p_reason: body.reason });
  if (error) fail(error);
  return DayClose.parse(data);
}
