// server/src/middleware/errorHandler.ts
//
// Mount LAST, after every route: app.use(errorHandler).
// Mount notFoundHandler immediately before it.
//
// Every response has the contract shape: { error: { code, message, details?, requestId } }.
// Raw database or internal messages never reach the client.

import type { Request, Response, NextFunction } from 'express';
import { ZodError } from 'zod';
import { errorCodeHttpStatus, type ErrorCode, type ErrorResponse } from '@ziadkhaled-wb/contracts';
import { AppError, mapDbError, safeMessage } from '../utils/errors';
import { SENSITIVE_KEYS, logger } from '../utils/logger';
import { captureServerError } from '../utils/monitoring';

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

interface ZodIssueLike {
  path: (string | number)[];
  code: string;
  message: string;
}

/**
 * Issues of a zod error, or undefined. Recognised by instanceof AND by name: the contracts
 * package carries its own zod copy, so its ZodError is a different class (D24).
 */
function zodErrorIssues(err: unknown): ZodIssueLike[] | undefined {
  if (err instanceof ZodError) return err.issues;
  if (typeof err !== 'object' || err === null) return undefined;
  const { name, issues } = err as { name?: unknown; issues?: unknown };
  if (name !== 'ZodError' || !Array.isArray(issues)) return undefined;
  return issues.map((raw: unknown) => {
    const issue = (typeof raw === 'object' && raw !== null ? raw : {}) as Partial<ZodIssueLike>;
    return {
      path: Array.isArray(issue.path) ? issue.path : [],
      code: typeof issue.code === 'string' ? issue.code : 'invalid',
      message: typeof issue.message === 'string' ? issue.message : 'Invalid value.',
    };
  });
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
    orgId: req.ctx?.orgId,
  };

  // Response already started: let Express close the connection.
  if (res.headersSent) {
    next(err);
    return;
  }

  // Q02: server errors (5xx) go to the error tracker with the request id (D35).
  const report = (code: string) =>
    captureServerError(err, {
      requestId: req.requestId,
      orgId: req.ctx?.orgId,
      userId: req.user?.id,
      method: req.method,
      // Express has already left the router here, so the mount path is gone: send both the
      // matched pattern and the URL path (query cut off: it can carry personal data).
      route: typeof req.route?.path === 'string' ? req.route.path : undefined,
      path: req.originalUrl.split('?')[0],
      code,
    });

  if (err instanceof AppError) {
    if (err.statusCode >= 500) {
      report(err.code);
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

  const zodIssues = zodErrorIssues(err);
  if (zodIssues) {
    const details = zodIssues.map((issue) => ({
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
    if (mapped.statusCode >= 500) report(mapped.code);
    log[level]({ ...logFields, code: mapped.code, err }, 'Request failed (database rule)');
    send(req, res, mapped.statusCode, mapped.code, mapped.message);
    return;
  }

  // Anything else: log the real error, return a generic one.
  report('INTERNAL');
  log.error({ ...logFields, err }, 'Unhandled server error');
  send(req, res, errorCodeHttpStatus.INTERNAL, 'INTERNAL', 'Internal server error.');
}

export function notFoundHandler(req: Request, res: Response) {
  send(req, res, errorCodeHttpStatus.NOT_FOUND, 'NOT_FOUND', 'Route not found.');
}
