// server/src/controllers/monitoring.controller.ts
import type { Request, Response } from 'express';

/** Thrown by POST /api/monitoring/test-error; recognisable in Sentry by its name. */
export class MonitoringTestError extends Error {
  override name = 'MonitoringTestError';
}

/** POST /api/monitoring/test-error: always fails with 500 (the error handler reports it). */
export function testError(_req: Request, _res: Response): Promise<void> {
  return Promise.reject(
    new MonitoringTestError('Deliberate test error from POST /api/monitoring/test-error (Q02)'),
  );
}
