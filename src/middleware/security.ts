// server/src/middleware/security.ts
//
// Security headers (helmet) and the strict CORS allow-list.

import cors from 'cors';
import helmet from 'helmet';
import type { Request, Response, NextFunction, RequestHandler } from 'express';

/** Defaults are right for a JSON API (CSP, HSTS, nosniff, frame denial, no referrer, ...). */
export function securityHeaders(): RequestHandler {
  const api = helmet();
  // Swagger UI (dev only, /docs) needs inline scripts and styles, so it gets helmet without CSP.
  const docs = helmet({ contentSecurityPolicy: false });
  return (req: Request, res: Response, next: NextFunction) => {
    const isDocs = req.path === '/docs' || req.path.startsWith('/docs/');
    (isDocs ? docs : api)(req, res, next);
  };
}

/**
 * Only origins in the allow-list get CORS headers. No `*`. Requests without an Origin header
 * (curl, server to server, health probes) are not browser cross-origin requests and pass through.
 */
export function corsAllowList(allowedOrigins: readonly string[]): RequestHandler {
  const allowed = new Set(allowedOrigins);
  return cors({
    origin(origin, callback) {
      callback(null, origin === undefined || allowed.has(origin));
    },
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
    allowedHeaders: [
      'Content-Type',
      'Authorization',
      'x-request-id',
      'x-org-id',
      'Idempotency-Key',
      'x-device-token',
    ],
    exposedHeaders: ['x-request-id'],
  });
}
