// server/src/server.ts
import { createApp } from './app.js';
import { docsRouter } from './docs/router.js';
import { env } from './utils/env.js';
import { logger } from './utils/logger.js';

const app = createApp(docsRouter);

const server = app.listen(env.PORT, () => {
  logger.info({ port: env.PORT, env: env.NODE_ENV }, 'API listening');
});

// Graceful shutdown — lets in-flight requests drain before exit.
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    logger.info({ signal }, 'Shutting down');
    server.close((err) => {
      if (err) {
        logger.error({ err }, 'Shutdown error');
        process.exit(1);
      }
      process.exit(0);
    });
  });
}
