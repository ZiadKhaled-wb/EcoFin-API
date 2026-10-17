import {
  OverdueAction,
  OverdueActionPage,
  OverdueListPage,
  OverdueRunResult,
  type DismissReferralBody,
  type HandleWarningBody,
  type LegalReferralListQuery,
  type OverdueListQuery,
  type OverdueWarningListQuery,
} from '@ziadkhaled-wb/contracts';
import type { Json } from '../types/database.types';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// N04 (D79). Overdue tracking: the daily check and every rule live in SQL (app.overdue_run and the
// public functions of 20261020090000_n04_overdue_tracking.sql); the API only shapes the calls. It
// never adds to what a customer owes (Islamic finance rule 4).

function fail(error: unknown): never {
  // The message and the Postgres code only: notes and reasons are never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'overdue database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** GET /api/overdue: overdue contracts, worst first, with totals and aging. */
export async function listOverdueContracts(
  ctx: RequestContext,
  query: OverdueListQuery,
): Promise<OverdueListPage> {
  const { data, error } = await ctx.db.rpc('list_overdue_contracts', { p_filters: query as Json });
  if (error) fail(error);
  return OverdueListPage.parse(data);
}

/** GET /api/overdue/warnings: the staff's work list. */
export async function listWarnings(
  ctx: RequestContext,
  query: OverdueWarningListQuery,
): Promise<OverdueActionPage> {
  const { data, error } = await ctx.db.rpc('list_overdue_warnings', { p_filters: query as Json });
  if (error) fail(error);
  return OverdueActionPage.parse(data);
}

/** POST /api/overdue/warnings/:id/handle. */
export async function handleWarning(
  ctx: RequestContext,
  id: string,
  body: HandleWarningBody,
): Promise<OverdueAction> {
  const { data, error } = await ctx.db.rpc('handle_overdue_warning', {
    p_id: id,
    p_outcome: body.outcome,
    ...(body.note === undefined ? {} : { p_note: body.note }),
  });
  if (error) fail(error);
  return OverdueAction.parse(data);
}

/** GET /api/overdue/legal-referrals. */
export async function listReferrals(
  ctx: RequestContext,
  query: LegalReferralListQuery,
): Promise<OverdueActionPage> {
  const { data, error } = await ctx.db.rpc('list_legal_referrals', { p_filters: query as Json });
  if (error) fail(error);
  return OverdueActionPage.parse(data);
}

/** POST /api/overdue/legal-referrals/:id/dismiss (the owner). */
export async function dismissReferral(
  ctx: RequestContext,
  id: string,
  body: DismissReferralBody,
): Promise<OverdueAction> {
  const { data, error } = await ctx.db.rpc('dismiss_legal_referral', {
    p_id: id,
    p_reason: body.reason,
  });
  if (error) fail(error);
  return OverdueAction.parse(data);
}

/** POST /api/overdue/run (the owner): the nightly check, now. */
export async function runCheck(ctx: RequestContext): Promise<OverdueRunResult> {
  const { data, error } = await ctx.db.rpc('run_overdue_check');
  if (error) fail(error);
  return OverdueRunResult.parse(data);
}
