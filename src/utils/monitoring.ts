// server/src/utils/monitoring.ts
//
// Q02 error tracking with Sentry (D35). Off unless SENTRY_DSN is set, so local runs and tests send
// nothing. Errors only: no tracing, no breadcrumbs (outgoing URLs can carry emails or ids).
// Every event carries the request id, so an error in Sentry, the API log line and the client's
// error response (`error.requestId`) can be matched.
//
// Privacy: no request bodies, headers, cookies or IP; keys that look sensitive (the logger's
// list) are replaced, and emails, 14-digit national ids, phone numbers and tokens are masked in
// every message and value before an event leaves the process.

import * as Sentry from '@sentry/node';
import type { ErrorEvent } from '@sentry/node';
import { SENSITIVE_KEYS } from './logger';

export interface MonitoringConfig {
  SENTRY_DSN?: string | undefined;
  SENTRY_ENVIRONMENT?: string | undefined;
  APP_RELEASE?: string | undefined;
  NODE_ENV: string;
  SERVICE_NAME: string;
}

let enabled = false;

const SENSITIVE = new Set(SENSITIVE_KEYS.map((key) => key.toLowerCase()));

/** Emails, Egyptian national ids (14 digits), mobile numbers, bearer tokens and JWTs. */
const MASKS: [RegExp, string][] = [
  [/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, '[email]'],
  [/(?<!\d)\d{14}(?!\d)/g, '[national-id]'],
  [/(?<!\d)(\+?20|0)1[0125]\d{8}(?!\d)/g, '[phone]'],
  [/Bearer\s+[\w.~+/=-]+/gi, 'Bearer [token]'],
  [/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '[jwt]'],
];

export function maskText(text: string): string {
  return MASKS.reduce((acc, [pattern, replacement]) => acc.replace(pattern, replacement), text);
}

function scrub(value: unknown, depth = 0): unknown {
  if (typeof value === 'string') return maskText(value);
  if (value === null || typeof value !== 'object' || depth > 6) return value;
  if (Array.isArray(value)) return value.map((v) => scrub(v, depth + 1));
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    out[k] = SENSITIVE.has(k.toLowerCase()) ? '[Redacted]' : scrub(v, depth + 1);
  }
  return out;
}

/** Runs on every event before it is sent. Exported for tests. */
export function scrubEvent(event: ErrorEvent): ErrorEvent {
  delete event.request;
  delete event.user;
  delete event.breadcrumbs;
  if (event.message) event.message = maskText(event.message);
  for (const ex of event.exception?.values ?? []) {
    if (ex.value) ex.value = maskText(ex.value);
  }
  if (event.extra) event.extra = scrub(event.extra) as Record<string, unknown>;
  if (event.contexts) event.contexts = scrub(event.contexts) as typeof event.contexts;
  if (event.tags) event.tags = scrub(event.tags) as typeof event.tags;
  return event;
}

/** Starts Sentry when SENTRY_DSN is set; returns whether it is on. Call once, first thing. */
export function initMonitoring(config: MonitoringConfig): boolean {
  if (!config.SENTRY_DSN) return false;
  Sentry.initWithoutDefaultIntegrations({
    dsn: config.SENTRY_DSN,
    environment: config.SENTRY_ENVIRONMENT ?? config.NODE_ENV,
    ...(config.APP_RELEASE ? { release: config.APP_RELEASE } : {}),
    // Error monitoring only. Unhandled rejections still end the process, as without Sentry.
    integrations: [
      ...Sentry.getDefaultIntegrationsWithoutPerformance().filter(
        (i) => i.name !== 'OnUnhandledRejection',
      ),
      Sentry.onUnhandledRejectionIntegration({ mode: 'strict' }),
    ],
    // Collect nothing about people or payloads; our tags (ids, route, code) are added by hand.
    dataCollection: {
      userInfo: false,
      cookies: false,
      httpHeaders: false,
      httpBodies: [],
      urlQueryParams: false,
      databaseQueryData: false,
      queues: false,
      stackFrameVariables: false,
    },
    maxBreadcrumbs: 0,
    initialScope: { tags: { service: config.SERVICE_NAME } },
    beforeSend: scrubEvent,
  });
  enabled = true;
  return true;
}

export function monitoringEnabled(): boolean {
  return enabled;
}

/** Where a server error happened. Only ids and route data, never bodies. */
export interface ErrorContext {
  requestId?: string | undefined;
  orgId?: string | undefined;
  userId?: string | undefined;
  method?: string | undefined;
  /** The matched route pattern, e.g. /:employeeId/permissions. */
  route?: string | undefined;
  /** The URL path without the query string. */
  path?: string | undefined;
  code?: string | undefined;
}

/** A 5xx in a request. Returns the Sentry event id (undefined when monitoring is off). */
export function captureServerError(err: unknown, context: ErrorContext): string | undefined {
  if (!enabled) return undefined;
  return Sentry.withScope((scope) => {
    for (const [key, value] of Object.entries(context)) {
      if (value !== undefined) scope.setTag(key, value);
    }
    return Sentry.captureException(err);
  });
}

/** A problem outside a request (a dead job, a ledger mismatch), with searchable tags. */
export function captureProblem(
  problem: unknown,
  tags: Record<string, string | number | null | undefined>,
  extra?: Record<string, unknown>,
): string | undefined {
  if (!enabled) return undefined;
  return Sentry.withScope((scope) => {
    scope.setLevel('error');
    for (const [key, value] of Object.entries(tags)) {
      if (value !== undefined && value !== null) scope.setTag(key, String(value));
    }
    if (extra) scope.setExtras(extra);
    return problem instanceof Error
      ? Sentry.captureException(problem)
      : Sentry.captureMessage(String(problem), 'error');
  });
}

/** Sends what is queued (on shutdown). */
export async function flushMonitoring(timeoutMs = 2000): Promise<void> {
  if (enabled) await Sentry.close(timeoutMs);
}
