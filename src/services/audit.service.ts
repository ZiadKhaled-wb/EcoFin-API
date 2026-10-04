// server/src/services/audit.service.ts
//
// F07: the owner's audit search. Reads public.audit_log through the caller's own client, so RLS
// (audit_log_tenant_read: same shop + audit.view) decides what is visible; the shop filter below
// comes from the session too (belt and braces), never from the request. Rows are already
// PII-stripped by app.write_audit. The actor's name comes from employees (readable in-shop).

import {
  AuditSearchResponse,
  type AuditRow,
  type AuditSearchQuery,
} from '@ziadkhaled-wb/contracts';
import type { RequestContext } from '../middleware/requestContext';
import { ServerError, mapDbError } from '../utils/errors';
import { logger } from '../utils/logger';

const COLUMNS =
  'id, branch_id, employee_id, super_admin_id, device_id, ip, user_agent, request_id, action, ' +
  'entity_type, entity_id, severity, reason, before, after, created_at, ' +
  'actor:employees!audit_log_employee_id_organization_id_fkey(full_name)';

interface DbAuditRow {
  id: number;
  branch_id: string | null;
  employee_id: string | null;
  super_admin_id: string | null;
  device_id: string | null;
  ip: unknown;
  user_agent: string | null;
  request_id: string | null;
  action: string;
  entity_type: string | null;
  entity_id: string | null;
  severity: AuditRow['severity'];
  reason: string | null;
  before: unknown;
  after: unknown;
  created_at: string;
  actor: { full_name: string } | null;
}

function toRow(r: DbAuditRow): AuditRow {
  return {
    id: r.id,
    branchId: r.branch_id,
    employeeId: r.employee_id,
    actorName: r.actor?.full_name ?? null,
    superAdminId: r.super_admin_id,
    deviceId: r.device_id,
    ip: r.ip === null || r.ip === undefined ? null : String(r.ip),
    userAgent: r.user_agent,
    requestId: r.request_id,
    action: r.action,
    entityType: r.entity_type,
    entityId: r.entity_id,
    severity: r.severity,
    reason: r.reason,
    before: r.before,
    after: r.after,
    // Postgres sends "2026-10-04 13:30:12.398+00" style; the contract wants ISO 8601.
    createdAt: new Date(r.created_at).toISOString(),
  };
}

function fail(err: unknown): never {
  const mapped = mapDbError(err);
  if (mapped) throw mapped;
  logger.error({ err }, 'audit search failed');
  throw ServerError('Request failed.');
}

export async function searchAudit(
  ctx: RequestContext,
  query: AuditSearchQuery,
): Promise<AuditSearchResponse> {
  const { page, pageSize } = query;
  const filtered = () => {
    let q = ctx.db
      .from('audit_log')
      .select(COLUMNS, { count: 'exact' })
      .eq('organization_id', ctx.orgId);
    if (query.from) q = q.gte('created_at', query.from);
    if (query.to) q = q.lte('created_at', query.to);
    if (query.actorEmployeeId) q = q.eq('employee_id', query.actorEmployeeId);
    if (query.action) q = q.eq('action', query.action);
    if (query.entityType) q = q.eq('entity_type', query.entityType);
    if (query.entityId) q = q.eq('entity_id', query.entityId);
    if (query.branchId) q = q.eq('branch_id', query.branchId);
    return q;
  };

  const offset = (page - 1) * pageSize;
  const { data, error, count } = await filtered()
    .order('created_at', { ascending: false })
    .order('id', { ascending: false })
    .range(offset, offset + pageSize - 1);

  // A page past the end: PostgREST answers 416 (PGRST103). Report the real total, no items.
  if (error && (error as { code?: string }).code === 'PGRST103') {
    const total = await filtered().limit(0);
    if (total.error) fail(total.error);
    return { items: [], page, pageSize, total: total.count ?? 0 };
  }
  if (error) fail(error);

  const parsed = AuditSearchResponse.safeParse({
    items: (data as unknown as DbAuditRow[]).map(toRow),
    page,
    pageSize,
    total: count ?? 0,
  });
  if (!parsed.success) {
    logger.error({ issues: parsed.error.issues }, 'audit search: rows outside the contract');
    throw ServerError('Request failed.');
  }
  return parsed.data;
}
