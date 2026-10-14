// T03 ETA submission monitor and corrections (EC-91). Everything goes through the caller's own client
// and the T03 database functions, which check the permission and the branch, and audit. The API never
// uses the service role here: a correction is queued (eta.correct) and built by the job worker.
import {
  FiscalAlertSummary,
  FiscalDaySummary,
  FiscalDetails,
  FiscalList,
  FiscalListItem,
  FiscalQueued,
  FiscalRetryManyResult,
  FiscalRetryResult,
  type FiscalDaySummaryQuery,
  type FiscalFix,
  type FiscalListQuery,
} from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import { parseEtaError } from '../eta/correct';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError, ServerError } from '../utils/errors';

function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** Where the ETA's complaint about a property is fixed. */
export function fixForProperty(path: string | null): FiscalFix {
  if (path === null) return 'support';
  const p = path.toLowerCase();
  if (p.startsWith('itemdata')) return 'product';
  if (p.startsWith('buyer')) return 'customer';
  if (p.includes('deviceserialnumber')) return 'device';
  if (p.includes('rin')) return 'shop_profile';
  if (p.includes('activitycode')) return 'eta_settings';
  if (p.startsWith('seller')) return 'branch';
  return 'support';
}

/** The ETA_REJECTED problem with the stored error parsed (message, property path, details). */
function withParsedEtaError(details: FiscalDetails): FiscalDetails {
  return {
    ...details,
    diagnosis: {
      ...details.diagnosis,
      problems: details.diagnosis.problems.map((problem) => {
        if (problem.code !== 'ETA_REJECTED') return problem;
        const parsed = parseEtaError(details.row.last_error);
        return {
          ...problem,
          fix: fixForProperty(parsed.propertyPath),
          eta_error: {
            message: parsed.message,
            property_path: parsed.propertyPath,
            details: parsed.details,
            nothing_changed: parsed.nothingChanged,
          },
        };
      }),
    },
  };
}

export async function list(ctx: RequestContext, query: FiscalListQuery): Promise<FiscalList> {
  const { data, error } = await ctx.db.rpc('fiscal_list', {
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
    ...(query.from ? { p_from: query.from } : {}),
    ...(query.to ? { p_to: query.to } : {}),
    ...(query.situation ? { p_situation: query.situation } : {}),
    ...(query.q ? { p_query: query.q } : {}),
    p_limit: query.limit,
    p_offset: query.offset,
  });
  if (error) fail(error);
  const rows = z.array(FiscalListItem.extend({ total_count: z.number().int() })).parse(data);
  const items = rows.map(({ total_count: _total, ...item }) => item);
  return { items, total_count: rows[0]?.total_count ?? 0 };
}

export async function alertSummary(ctx: RequestContext): Promise<FiscalAlertSummary> {
  const { data, error } = await ctx.db.rpc('fiscal_alert_summary');
  if (error) fail(error);
  return FiscalAlertSummary.parse(data);
}

export async function daySummary(
  ctx: RequestContext,
  query: FiscalDaySummaryQuery,
): Promise<FiscalDaySummary> {
  const { data, error } = await ctx.db.rpc('fiscal_day_summary', {
    p_branch_id: query.branch_id,
    p_business_date: query.date,
  });
  if (error) fail(error);
  return FiscalDaySummary.parse(data);
}

export async function details(ctx: RequestContext, id: string): Promise<FiscalDetails> {
  const { data, error } = await ctx.db.rpc('fiscal_details', { p_id: id });
  if (error) fail(error);
  return withParsedEtaError(FiscalDetails.parse(data));
}

/** T02's retry: a blocked or send_failed receipt. A rejected one is USE_CORRECTION. */
export async function retry(ctx: RequestContext, id: string): Promise<FiscalRetryResult> {
  const { data, error } = await ctx.db.rpc('retry_fiscal_submission', { p_id: id });
  if (error) fail(error);
  return FiscalRetryResult.parse(data);
}

export async function correct(ctx: RequestContext, id: string): Promise<FiscalQueued> {
  const { data, error } = await ctx.db.rpc('fiscal_request_correction', { p_id: id });
  if (error) fail(error);
  return FiscalQueued.parse(data);
}

export async function assignDevice(
  ctx: RequestContext,
  id: string,
  deviceId: string,
): Promise<FiscalRetryResult> {
  const { data, error } = await ctx.db.rpc('fiscal_assign_device', {
    p_id: id,
    p_device_id: deviceId,
  });
  if (error) fail(error);
  return FiscalRetryResult.parse(data);
}

export async function checkNow(ctx: RequestContext, id: string): Promise<FiscalQueued> {
  const { data, error } = await ctx.db.rpc('fiscal_check_now', { p_id: id });
  if (error) fail(error);
  return FiscalQueued.parse(data);
}

export async function retryMany(
  ctx: RequestContext,
  ids: string[],
): Promise<FiscalRetryManyResult> {
  const { data, error } = await ctx.db.rpc('fiscal_retry_many', { p_ids: ids });
  if (error) fail(error);
  return FiscalRetryManyResult.parse(data);
}
