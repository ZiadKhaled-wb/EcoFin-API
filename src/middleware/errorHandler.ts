// server/src/middleware/errorHandler.ts
//
// Mount LAST, after every route: app.use(errorHandler).
// Mount notFoundHandler immediately before it.
//
// Every response has the contract shape: { error: { code, message, details?, requestId } }.
// Raw database or internal messages never reach the client.

import type { Request, Response, NextFunction } from 'express';
import { ZodError } from 'zod';
import { errorCodeHttpStatus, type ErrorCode, type ErrorResponse } from '@ecotech/contracts';
import { AppError, mapDbError, safeMessage } from '../utils/errors';
import { SENSITIVE_KEYS, logger } from '../utils/logger';

// Fields we never want to echo back to a client, no matter what a service
// attached to err.details.
// Same list as the logger redaction, compared case-insensitively.
const SENSITIVE_DETAIL_KEYS = new Set(SENSITIVE_KEYS.map((key) => key.toLowerCase()));

function sanitizeDetails(details: unknown): unknown {
  if (details == null) return undefined;
  if (typeof details !== 'object') return details;
  if (Array.isArray(details)) return details.map(sanitizeDetails);
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(details as Record<string, unknown>)) {
    out[k] = SENSITIVE_DETAIL_KEYS.has(k.toLowerCase()) ? '[Redacted]' : sanitizeDetails(v);
  }
  return out;
}

function send(
  req: Request,
  res: Response,
  status: number,
  code: ErrorCode,
  message: string,
  details?: unknown,
): void {
  const requestId = req.requestId;
  const body: ErrorResponse = {
    error: {
      code,
      message,
      ...(details !== undefined ? { details } : {}),
      ...(requestId !== undefined ? { requestId } : {}),
    },
  };
  res.status(status).json(body);
}

/** Errors raised by express.json() (invalid JSON, body too large). */
function bodyParserMessage(err: unknown): string | undefined {
  if (typeof err !== 'object' || err === null) return undefined;
  const type = (err as { type?: unknown }).type;
  if (type === 'entity.parse.failed') return 'Request body is not valid JSON.';
  if (type === 'entity.too.large') return 'Request body is too large.';
  if (type === 'encoding.unsupported' || type === 'charset.unsupported') {
    return 'Request body encoding is not supported.';
  }
  return undefined;
}

export function errorHandler(err: unknown, req: Request, res: Response, next: NextFunction) {
  const log = req.log ?? logger;
  const logFields = {
    // The request logger child already carries the request id.
    ...(req.log ? {} : { requestId: req.requestId }),
    method: req.method,
    path: req.path,
    userId: req.user?.id,
    orgId: req.employee?.organization_id,
  };

  // Response already started: let Express close the connection.
  if (res.headersSent) {
    next(err);
    return;
  }

  if (err instanceof AppError) {
    if (err.statusCode >= 500) {
      log.error({ ...logFields, code: err.code, err }, 'Request failed (server)');
      send(req, res, err.statusCode, err.code, safeMessage(err.code));
      return;
    }
    log.warn(
      { ...logFields, code: err.code, statusCode: err.statusCode },
      'Request failed (client)',
    );
    send(req, res, err.statusCode, err.code, err.message, sanitizeDetails(err.details));
    return;
  }

  if (err instanceof ZodError) {
    const details = err.issues.map((issue) => ({
      path: issue.path.join('.'),
      code: issue.code,
      message: issue.message,
    }));
    log.warn({ ...logFields, code: 'VALIDATION_FAILED' }, 'Request failed (validation)');
    send(
      req,
      res,
      errorCodeHttpStatus.VALIDATION_FAILED,
      'VALIDATION_FAILED',
      'Validation failed.',
      details,
    );
    return;
  }

  const parserMessage = bodyParserMessage(err);
  if (parserMessage !== undefined) {
    log.warn({ ...logFields, code: 'BAD_REQUEST' }, 'Request failed (body)');
    send(req, res, errorCodeHttpStatus.BAD_REQUEST, 'BAD_REQUEST', parserMessage);
    return;
  }

  // Postgres / Supabase error whose message starts with a contract code.
  const mapped = mapDbError(err);
  if (mapped) {
    const level = mapped.statusCode >= 500 ? 'error' : 'warn';
    log[level]({ ...logFields, code: mapped.code, err }, 'Request failed (database rule)');
    send(req, res, mapped.statusCode, mapped.code, mapped.message);
    return;
  }

  // Anything else: log the real error, return a generic one.
  log.error({ ...logFields, err }, 'Unhandled server error');
  send(req, res, errorCodeHttpStatus.INTERNAL, 'INTERNAL', 'Internal server error.');
}

export function notFoundHandler(req: Request, res: Response) {
  send(req, res, errorCodeHttpStatus.NOT_FOUND, 'NOT_FOUND', 'Route not found.');
}
