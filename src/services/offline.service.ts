import {
  offlineActionsFor,
  OfflineLeaseResponse,
  OfflineSaleDetail,
  OfflineSaleList,
  OfflineSaleSummary,
  OfflineSettings,
  OfflineSyncResponse,
  type OfflineImportBody,
  type OfflineLeaseBody,
  type OfflineResolveBody,
  type OfflineSaleListQuery,
  type OfflineSettingsBody,
  type OfflineSyncBody,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { etaRuntime } from '../eta/runtime';
import { captureProblem } from '../utils/monitoring';
import { logger } from '../utils/logger';
import { mapDbError, ServerError } from '../utils/errors';

// S08 offline cash sales (EC-75). Every rule is in SQL (supabase/migrations/20261031090000_s08_offline_sales.sql);
// this layer passes the bodies, parses the answers with the contracts, adds the shop's ETA portal to
// the lease (the QR link) and sends the item problems to Q02. A content, a signature or a device
// token is never logged: ids, numbers and codes only.
function fail(error: unknown): never {
  throw mapDbError(error) ?? ServerError('Request failed.');
}

/** Item codes someone must look at (the database also writes a critical audit row). */
const ALERT_CODES = new Set([
  'SEQ_REUSED',
  'NOT_OURS',
  'RECEIPT_MISMATCH',
  'INVALID_CONTENT',
  'UUID_TAKEN',
  'KEY_REUSED',
]);

function alertItems(
  ctx: RequestContext,
  source: 'sync' | 'import',
  results: OfflineSyncResponse['results'],
): void {
  for (const item of results) {
    if (item.code === null || !ALERT_CODES.has(item.code)) continue;
    const tags = { problem: 'offline', source, orgId: ctx.orgId, seq: item.seq, code: item.code };
    logger.error(tags, 'offline sale refused or held');
    captureProblem(`offline: ${item.code}`, tags);
  }
}

const LeaseRow = OfflineLeaseResponse.extend({
  eta: OfflineLeaseResponse.shape.eta.omit({ portal_url: true }),
});

export async function lease(ctx: RequestContext, body: OfflineLeaseBody) {
  const { data, error } = await ctx.db.rpc('issue_offline_lease', {
    p_public_key: body.public_key,
    ...(body.snapshot_hash ? { p_snapshot_hash: body.snapshot_hash } : {}),
  });
  if (error) fail(error);
  const row = LeaseRow.parse(data);
  const environment = row.eta.environment;
  return OfflineLeaseResponse.parse({
    ...row,
    eta: {
      ...row.eta,
      portal_url: environment ? etaRuntime().hosts[environment].portalUrl : null,
    },
  });
}

export async function sync(ctx: RequestContext, body: OfflineSyncBody) {
  const { data, error } = await ctx.db.rpc('sync_offline_sales', { p_items: body.items });
  if (error) fail(error);
  const answer = OfflineSyncResponse.parse(data);
  alertItems(ctx, 'sync', answer.results);
  return answer;
}

export async function importItems(ctx: RequestContext, body: OfflineImportBody) {
  const { data, error } = await ctx.db.rpc('import_offline_sales', {
    p_device_id: body.device_id,
    p_items: body.items,
  });
  if (error) fail(error);
  const answer = OfflineSyncResponse.parse(data);
  alertItems(ctx, 'import', answer.results);
  return answer;
}

export async function list(ctx: RequestContext, query: OfflineSaleListQuery) {
  const { data, error } = await ctx.db.rpc('list_offline_sales', {
    ...(query.status ? { p_status: query.status } : {}),
    ...(query.branch_id ? { p_branch_id: query.branch_id } : {}),
  });
  if (error) fail(error);
  return OfflineSaleList.parse(data);
}

const DetailRow = OfflineSaleDetail.omit({ actions: true });

export async function get(ctx: RequestContext, id: string) {
  const { data, error } = await ctx.db.rpc('get_offline_sale', { p_id: id });
  if (error) fail(error);
  const row = DetailRow.parse(data);
  return OfflineSaleDetail.parse({ ...row, actions: offlineActionsFor(row) });
}

export async function resolve(ctx: RequestContext, id: string, body: OfflineResolveBody) {
  const { data, error } = await ctx.db.rpc('resolve_offline_sale', {
    p_id: id,
    p_action: body.action,
    p_reason: body.reason,
    ...(body.unit_ids ? { p_unit_ids: body.unit_ids } : {}),
    ...(body.shift_id ? { p_shift_id: body.shift_id } : {}),
  });
  if (error) fail(error);
  return OfflineSaleSummary.parse(data);
}

export async function getSettings(ctx: RequestContext) {
  const { data, error } = await ctx.db.rpc('get_offline_settings');
  if (error) fail(error);
  return OfflineSettings.parse(data);
}

export async function setSettings(ctx: RequestContext, body: OfflineSettingsBody) {
  const { data, error } = await ctx.db.rpc('set_offline_settings', {
    p_enabled: body.offline_enabled,
    p_max_sale_total: body.offline_max_sale_total,
    p_max_hours: body.offline_max_hours,
    p_max_sales: body.offline_max_sales,
    p_max_lease_total: body.offline_max_lease_total,
  });
  if (error) fail(error);
  return OfflineSettings.parse(data);
}
