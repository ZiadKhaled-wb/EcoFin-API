import { z } from 'zod';
import { IsoTimestamp, PaginationQuery, Uuid, paginated } from './common.js';

/** Values of `public.audit_severity`. */
export const AuditSeverity = z.enum(['info', 'warning', 'critical']);
export type AuditSeverity = z.infer<typeof AuditSeverity>;

// F07 · GET /audit
export const AuditSearchQuery = PaginationQuery.extend({
  from: IsoTimestamp.optional(),
  to: IsoTimestamp.optional(),
  actorEmployeeId: Uuid.optional(),
  action: z.string().min(1).max(100).optional(),
  entityType: z.string().min(1).max(100).optional(),
  entityId: Uuid.optional(),
  branchId: Uuid.optional(),
})
  .strict()
  .refine(
    (q) => q.from === undefined || q.to === undefined || Date.parse(q.from) <= Date.parse(q.to),
    { message: '`from` must not be after `to`', path: ['from'] },
  );

/** One row of `public.audit_log` (organization_id is never sent: the caller's shop is implied). */
export const AuditRow = z.object({
  id: z.number().int(),
  branchId: Uuid.nullable(),
  employeeId: Uuid.nullable(),
  /** The acting employee's full name (0.3.0); null for platform/service actions. */
  actorName: z.string().nullable(),
  superAdminId: Uuid.nullable(),
  deviceId: Uuid.nullable(),
  ip: z.string().nullable(),
  userAgent: z.string().nullable(),
  requestId: z.string().nullable(),
  action: z.string(),
  entityType: z.string().nullable(),
  entityId: Uuid.nullable(),
  severity: AuditSeverity,
  reason: z.string().nullable(),
  before: z.unknown(),
  after: z.unknown(),
  createdAt: IsoTimestamp,
});
export type AuditRow = z.infer<typeof AuditRow>;

export const AuditSearchResponse = paginated(AuditRow);
export const AuditSearch = { query: AuditSearchQuery, response: AuditSearchResponse };
export type AuditSearchQuery = z.infer<typeof AuditSearchQuery>;
export type AuditSearchResponse = z.infer<typeof AuditSearchResponse>;
