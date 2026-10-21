// server/src/jobs/registry.ts
//
// Every job type the API runs, and the daily ones (D34). Add a slice's job here: a handler that is
// safe to run twice (a retry after a crash can repeat it), plus a DAILY entry if it's scheduled.
//   T02 'eta.prepare', 'eta.submit', 'eta.poll' (D67): queued by the database with each sale and
//   each receipt status change, not daily.
//   M01 'import.apply' (D83): queued by public.queue_import when the owner runs a validated import.
//   N04 'installments.overdue' (daily, D79): warnings, bans and legal referrals; never a late fee
//   (Islamic finance rule 4).
//   M03 'export.full' (D86): queued by public.start_full_export; 'export.cleanup' (daily 04:00)
//   removes zips older than 7 days.
//   K04 'day.check' (daily, D84): yesterday's day-close checks per branch and drift on closed days;
//   never closes a day. Q03 backups check: added by that slice.

import type { SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from 'pino';
import { etaJobHandlers } from '../eta/jobs';
import { etaRuntime } from '../eta/runtime';
import { supabaseEtaStore } from '../eta/store';
import { dayCheck } from './handlers/dayCheck';
import { exportCleanup } from './handlers/exportCleanup';
import { exportFull, pgSnapshot } from './handlers/exportFull';
import { importApply } from './handlers/importApply';
import { ledgerReconcile } from './handlers/ledgerReconcile';
import { overdueCheck } from './handlers/overdueCheck';
import { supabaseJobStore } from './store';
import type { DailyJob, JobHandler } from './types';
import { JobWorker } from './worker';

/** The direct Postgres connection of the full export; null (the export then fails) without DATABASE_URL. */
function exportSnapshot() {
  const url = process.env['DATABASE_URL'];
  return url ? pgSnapshot(url) : null;
}

export function jobHandlers(db: SupabaseClient, logger: Logger): Record<string, JobHandler> {
  const { client, hosts } = etaRuntime();
  return {
    'ledger.reconcile': ledgerReconcile(db),
    'installments.overdue': overdueCheck(db),
    'day.check': dayCheck(db),
    // M01 (D83): queued by public.queue_import, not daily.
    'import.apply': importApply(db),
    // M03 (D86): queued by public.start_full_export; export.cleanup is daily.
    'export.full': exportFull({ db, openSnapshot: exportSnapshot() }),
    'export.cleanup': exportCleanup(db),
    ...etaJobHandlers({ store: supabaseEtaStore(db), client, hosts, logger }),
  };
}

/** Local time in each shop's own time zone (organizations.timezone, Africa/Cairo by default). */
export const DAILY_JOBS: readonly DailyJob[] = [
  // Before the shop's day starts, so the morning's overdue list is ready.
  { type: 'installments.overdue', localTime: '00:30' },
  { type: 'ledger.reconcile', localTime: '03:00' },
  // After ledger.reconcile, so the night's mismatch log comes first (K04, D84).
  { type: 'day.check', localTime: '03:30' },
  // M03: zips older than 7 days leave storage.
  { type: 'export.cleanup', localTime: '04:00' },
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
