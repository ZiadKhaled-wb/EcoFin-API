// server/src/app.ts
import express from 'express';
import type { Router } from 'express';
import auditRoutes from './routes/audit.js';
import authRoutes from './routes/auth.js';
import employeesRoutes from './routes/employees.js';
import healthRoutes from './routes/health.js';
import meRoutes from './routes/me.js';
import { errorHandler, notFoundHandler } from './middleware/errorHandler.js';
import { noClientOrg } from './middleware/noClientOrg.js';
import { requestId } from './middleware/requestId.js';
import { mountRouter } from './routes/registry.js';
import { corsAllowList, securityHeaders } from './middleware/security.js';
import { getEnv, type Env } from './utils/env.js';

export interface CreateAppOptions {
  /** Swagger UI router, mounted at /docs. */
  docsRouter?: Router;
  /** Parsed env. Defaults to the cached process env (validated on startup). */
  env?: Pick<Env, 'TRUST_PROXY' | 'CORS_ALLOWED_ORIGINS'>;
}

export function createApp(options: CreateAppOptions = {}) {
  const env = options.env ?? getEnv();
  const app = express();

  // Number of reverse-proxy hops to trust for req.ip (and so the rate limiter's key).
  app.set('trust proxy', env.TRUST_PROXY);
  app.disable('x-powered-by');

  app.use(requestId());
  app.use(securityHeaders());
  app.use(corsAllowList(env.CORS_ALLOWED_ORIGINS));
  app.use(express.json({ limit: '1mb' }));
  // F05: the shop comes from the session, never from the body or query.
  app.use(noClientOrg);

  // Routers go through mountRouter so listRoutes() (D19 route checks) can see them.
  mountRouter(app, '/health', healthRoutes);

  // API docs — no auth, dev-only by default. Mount BEFORE the 404 handler.
  if (options.docsRouter) mountRouter(app, '/docs', options.docsRouter);

  mountRouter(app, '/api/auth', authRoutes);
  mountRouter(app, '/api/me', meRoutes);
  mountRouter(app, '/api/employees', employeesRoutes);
  mountRouter(app, '/api/audit', auditRoutes);

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
