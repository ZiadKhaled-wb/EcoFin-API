// src/test/audit-registry/registry.ts
//
// F07 / D19: every write route (any method but GET) says which audit_log action it produces, or
// explicitly `none` with the reason. `npm run check:audit` and check.test.ts fail when a write
// route is missing here; audit.integration.test.ts calls each route that has an action and
// asserts exactly one new audit_log row with that action, the request id and the client IP.

export type AuditExpectation = { action: string } | { none: string };

/** Keyed `METHOD /path` as mounted (same keys as the cross-shop and permission checks). */
export const AUDIT_REGISTRY: Readonly<Record<string, AuditExpectation>> = {
  'POST /api/auth/login': { action: 'auth.login' },
  'POST /api/auth/refresh': {
    none: 'Token refresh changes no data; the session was audited at login.',
  },
  'POST /api/auth/forgot-password': {
    none: 'Public, no session and no shop yet; only an email is sent (always 202).',
  },
  'POST /api/auth/reset-password': {
    none: 'A login may belong to several shops, so there is no single shop log; attempts are in login_attempts (user decision, 4 Oct).',
  },
  'POST /api/auth/logout': { action: 'auth.logout' },
  'POST /api/auth/select-shop': { action: 'auth.login' },
  'POST /api/auth/change-password': { action: 'auth.password_change' },
  'PUT /api/employees/:employeeId/permissions': { action: 'employee.permission_set' },
  'PUT /api/employees/:employeeId/branches': { action: 'employee.branches_set' },
  'POST /api/files': { action: 'file.upload' },
  'POST /api/monitoring/test-error': {
    none: 'Monitoring test (Q02): writes nothing, only raises an error on purpose.',
  },
};
