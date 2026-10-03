// server/src/app.ts
import express, { type Request, type Response, type NextFunction } from 'express';
import type { Router } from 'express';
import cors from 'cors';
import { randomUUID } from 'node:crypto';
import authRoutes from './routes/auth.js';
import { errorHandler, notFoundHandler } from './middleware/errorHandler.js';
import { env } from './utils/env.js';

export function createApp(docsRouter?: Router) {
  const app = express();

  app.set('trust proxy', 1);

  // CORS — allow the frontend origin to make cross-origin requests
  app.use(
    cors({
      origin: env.FRONTEND_URL,
      credentials: true,
      methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
      allowedHeaders: ['Content-Type', 'Authorization', 'x-request-id'],
    }),
  );

  app.use(express.json({ limit: '1mb' }));

  app.use((req: Request, res: Response, next: NextFunction) => {
    const headerId = req.headers['x-request-id'];
    req.requestId = typeof headerId === 'string' && headerId.length > 0 ? headerId : randomUUID();
    res.setHeader('x-request-id', req.requestId);
    next();
  });

  app.get('/health', (_req, res) => {
    res.json({ ok: true, service: env.SERVICE_NAME, env: env.NODE_ENV });
  });

  // API docs — no auth, dev-only by default. Mount BEFORE the 404 handler.
  if (docsRouter) app.use('/docs', docsRouter);

  app.use('/api/auth', authRoutes);

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
