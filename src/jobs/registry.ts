// server/src/jobs/registry.ts
//
// Every job type the API runs, and the daily ones (D34). Add a slice's job here: a handler that is
// safe to run twice (a retry after a crash can repeat it), plus a DAILY entry if it's scheduled.
//   T02 'eta.prepare', 'eta.submit', 'eta.poll' (D67): queued by the database with each sale and
//   each receipt status change, not daily.
//   N04 'installments.overdue' (daily, D79): warnings, bans and legal referrals; never a late fee
//   (Islamic finance rule 4). K04 daily reconciliation, Q03 backups check: added by those slices.

import type { SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from 'pino';
import { etaJobHandlers } from '../eta/jobs';
import { etaRuntime } from '../eta/runtime';
import { supabaseEtaStore } from '../eta/store';
import { ledgerReconcile } from './handlers/ledgerReconcile';
import { overdueCheck } from './handlers/overdueCheck';
import { supabaseJobStore } from './store';
import type { DailyJob, JobHandler } from './types';
import { JobWorker } from './worker';

export function jobHandlers(db: SupabaseClient, logger: Logger): Record<string, JobHandler> {
  const { client, hosts } = etaRuntime();
  return {
    'ledger.reconcile': ledgerReconcile(db),
    'installments.overdue': overdueCheck(db),
    ...etaJobHandlers({ store: supabaseEtaStore(db), client, hosts, logger }),
  };
}

/** Local time in each shop's own time zone (organizations.timezone, Africa/Cairo by default). */
export const DAILY_JOBS: readonly DailyJob[] = [
  // Before the shop's day starts, so the morning's overdue list is ready.
  { type: 'installments.overdue', localTime: '00:30' },
  { type: 'ledger.reconcile', localTime: '03:00' },
];

export function createJobWorker(
  db: SupabaseClient,
  logger: Logger,
  options: { pollSeconds: number },
): JobWorker {
  return new JobWorker({
    store: supabaseJobStore(db),
    handlers: jobHandlers(db, logger),
    daily: DAILY_JOBS,
    logger,
    pollSeconds: options.pollSeconds,
  });
}
