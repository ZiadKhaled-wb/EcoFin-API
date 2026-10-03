// server/src/app.ts
import express from 'express';
import type { Router } from 'express';
import authRoutes from './routes/auth.js';
import healthRoutes from './routes/health.js';
import { errorHandler, notFoundHandler } from './middleware/errorHandler.js';
import { requestId } from './middleware/requestId.js';
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

  app.use('/health', healthRoutes);

  // API docs — no auth, dev-only by default. Mount BEFORE the 404 handler.
  if (options.docsRouter) app.use('/docs', options.docsRouter);

  app.use('/api/auth', authRoutes);

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
