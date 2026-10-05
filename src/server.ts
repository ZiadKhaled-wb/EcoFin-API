// server/src/server.ts
import { createApp } from './app.js';
import { docsRouter } from './docs/router.js';
import { createJobWorker } from './jobs/registry.js';
import { getEnv } from './utils/env.js';
import { logger } from './utils/logger.js';
import { supabaseAdmin } from './utils/supabase.js';

// Validate the environment first: a missing or bad variable stops the server with one clear message.
let env: ReturnType<typeof getEnv>;
try {
  env = getEnv();
} catch (err) {
  logger.fatal(err instanceof Error ? err.message : 'Invalid environment configuration');
  process.exit(1);
}

const app = createApp({ docsRouter, env });

const server = app.listen(env.PORT, () => {
  logger.info({ port: env.PORT, env: env.NODE_ENV }, 'API listening');
});

// F13 (D34): background jobs run in this process; the database keeps several instances apart.
const jobs = env.JOBS_ENABLED
  ? createJobWorker(supabaseAdmin, logger, { pollSeconds: env.JOBS_POLL_SECONDS })
  : undefined;
jobs?.start();

// Graceful shutdown — lets in-flight requests drain before exit.
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    logger.info({ signal }, 'Shutting down');
    // A job in progress finishes first; an unfinished one would be retried after 15 minutes anyway.
    void (jobs?.stop() ?? Promise.resolve()).finally(() =>
      server.close((err) => {
        if (err) {
          logger.error({ err }, 'Shutdown error');
          process.exit(1);
        }
        process.exit(0);
      }),
    );
  });
}
