// server/src/middleware/errorHandler.ts
//
// Mount LAST, after every route: app.use(errorHandler).
// Mount notFoundHandler immediately before it.

import type { Request, Response, NextFunction } from 'express';
import { AppError } from '../utils/errors';
import { logger } from '../utils/logger';

// Fields we never want to echo back to a client, no matter what a service
// attached to err.details.
const SENSITIVE_KEYS = new Set([
  'password',
  'confirmPassword',
  'newPassword',
  'currentPassword',
  'license_key',
  'token',
  'access_token',
  'refresh_token',
  'jwt',
  'authorization',
]);

function sanitizeDetails(details: unknown): unknown {
  if (details == null) return undefined;
  if (typeof details !== 'object') return details;
  if (Array.isArray(details)) return details.map(sanitizeDetails);
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(details as Record<string, unknown>)) {
    out[k] = SENSITIVE_KEYS.has(k) ? '[REDACTED]' : sanitizeDetails(v);
  }
  return out;
}

function requestIdOf(req: Request): string {
  if (req.requestId) return req.requestId;
  const header = req.headers['x-request-id'];
  return typeof header === 'string' && header.length > 0 ? header : 'unknown';
}

export function errorHandler(err: unknown, req: Request, res: Response, _next: NextFunction) {
  const requestId = requestIdOf(req);

  if (err instanceof AppError) {
    const body: Record<string, unknown> = {
      error: err.message,
      code: err.code,
      requestId,
    };
    const details = sanitizeDetails(err.details);
    if (details !== undefined) body.details = details;

    const logFields = {
      code: err.code,
      statusCode: err.statusCode,
      requestId,
      method: req.method,
      url: req.url,
      userId: req.user?.id,
      orgId: req.employee?.organization_id,
    };
    if (err.statusCode >= 500) {
      logger.error({ ...logFields, err: err.stack ?? err.message }, 'Request failed (server)');
    } else {
      logger.warn(logFields, 'Request failed (client)');
    }

    res.status(err.statusCode).json(body);
    return;
  }

  // Anything else — a raw Error, a Supabase error object, a thrown string.
  // Never leak the shape to the client.
  logger.error(
    {
      err: err instanceof Error ? { message: err.message, stack: err.stack } : err,
      requestId,
      method: req.method,
      url: req.url,
      userId: req.user?.id,
    },
    'Unhandled server error',
  );
  res.status(500).json({
    error: 'حدث خطأ غير متوقع في الخادم',
    code: 'INTERNAL',
    requestId,
  });
}

export function notFoundHandler(req: Request, res: Response) {
  res.status(404).json({
    error: 'المسار غير موجود',
    code: 'NOT_FOUND',
    requestId: requestIdOf(req),
  });
}
