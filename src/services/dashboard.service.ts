import { OwnerDashboard, type DashboardQuery } from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';
import { logger } from '../utils/logger';

// D01 (D87). The owner dashboard: every number is computed in SQL by the same definition as the page
// it links to (20261028090000_d01_owner_dashboard.sql); the API passes the branch and parses the answer.

function fail(error: unknown): never {
  // The message and the Postgres code only: amounts are never logged.
  const { message, code } = (error ?? {}) as { message?: unknown; code?: unknown };
  logger.error({ err: { message, code } }, 'dashboard database request failed');
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** GET /api/dashboard: today's tiles for all the caller's branches or one branch. */
export async function getOwnerDashboard(
  ctx: RequestContext,
  query: DashboardQuery,
): Promise<OwnerDashboard> {
  const { data, error } = await ctx.db.rpc('get_owner_dashboard', {
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
  });
  if (error) fail(error);
  return OwnerDashboard.parse(data);
}
