// server/src/middleware/requestId.ts
//
// Mount FIRST. Gives every request an id (the caller's `x-request-id` when it is a safe token,
// otherwise a fresh UUID), echoes it in the response header, and attaches a logger child that
// carries it. Logs one line per finished request (method, path, status, duration; never headers,
// body or query string).

import { randomUUID } from 'node:crypto';
import type { Request, Response, NextFunction } from 'express';
import type { Logger } from 'pino';
import { logger as rootLogger } from '../utils/logger';

declare module 'express-serve-static-core' {
  interface Request {
    /** Logger child carrying the request id. */
    log: Logger;
  }
}

const SAFE_REQUEST_ID = /^[A-Za-z0-9._-]{1,128}$/;

export function resolveRequestId(header: unknown): string {
  return typeof header === 'string' && SAFE_REQUEST_ID.test(header) ? header : randomUUID();
}

export function requestId(baseLogger: Logger = rootLogger) {
  return (req: Request, res: Response, next: NextFunction): void => {
    req.requestId = resolveRequestId(req.headers['x-request-id']);
    res.setHeader('x-request-id', req.requestId);
    req.log = baseLogger.child({ requestId: req.requestId });

    const startedAt = process.hrtime.bigint();
    res.on('finish', () => {
      req.log.info(
        {
          method: req.method,
          path: req.path,
          statusCode: res.statusCode,
          durationMs: Number((process.hrtime.bigint() - startedAt) / 1_000_000n),
        },
        'request completed',
      );
    });
    next();
  };
}
