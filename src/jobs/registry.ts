// server/src/jobs/registry.ts
//
// Every job type the API runs, and the daily ones (D34). Add a slice's job here: a handler that is
// safe to run twice (a retry after a crash can repeat it), plus a DAILY entry if it's scheduled.
//   N04 'installments.assess_late_fees' (daily), T02 'eta.submit' (queued by sales, retried),
//   K04 daily reconciliation, Q03 backups check: added by those slices.

import type { SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from 'pino';
import { ledgerReconcile } from './handlers/ledgerReconcile';
import { supabaseJobStore } from './store';
import type { DailyJob, JobHandler } from './types';
import { JobWorker } from './worker';

export function jobHandlers(db: SupabaseClient): Record<string, JobHandler> {
  return {
    'ledger.reconcile': ledgerReconcile(db),
  };
}

/** Local time in each shop's own time zone (organizations.timezone, Africa/Cairo by default). */
export const DAILY_JOBS: readonly DailyJob[] = [{ type: 'ledger.reconcile', localTime: '03:00' }];

export function createJobWorker(
  db: SupabaseClient,
  logger: Logger,
  options: { pollSeconds: number },
): JobWorker {
  return new JobWorker({
    store: supabaseJobStore(db),
    handlers: jobHandlers(db),
    daily: DAILY_JOBS,
    logger,
    pollSeconds: options.pollSeconds,
  });
}
