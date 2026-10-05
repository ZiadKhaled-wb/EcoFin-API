// server/src/jobs/handlers/ledgerReconcile.ts
//
// Daily 'ledger.reconcile' (F10 + F13, D33/D34): checks that every cached stock level, cash
// balance and store-credit balance of the shop still equals the sum of its ledger. A mismatch is
// a finding, not a failure: retrying wouldn't change it, so the job succeeds and logs it at error
// level (Q02 turns that log into an alert). Read-only, so running it twice is harmless.

import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { captureProblem } from '../../utils/monitoring';
import type { JobHandler } from '../types';

const Mismatch = z.object({
  ledger: z.string(),
  subject_id: z.string().uuid(),
  branch_id: z.string().uuid().nullable(),
  detail: z.string().nullable(),
  cached: z.union([z.number(), z.string()]),
  from_ledger: z.union([z.number(), z.string()]),
});

/** Mismatches listed in one log line at most; the count is always exact. */
const LOGGED = 50;

export function ledgerReconcile(db: SupabaseClient): JobHandler {
  return async (job, log) => {
    if (!job.organizationId) throw new Error('ledger.reconcile needs a shop');
    const { data, error } = await db.rpc('jobs_ledger_mismatches', {
      p_organization_id: job.organizationId,
    });
    if (error) throw new Error(`jobs_ledger_mismatches failed: ${error.message}`);
    const mismatches = z.array(Mismatch).parse(data);
    if (mismatches.length > 0) {
      log.error(
        { count: mismatches.length, mismatches: mismatches.slice(0, LOGGED) },
        'ledger.reconcile: cached balances do not match their ledger',
      );
      // Q02 (D35): alert through the error tracker (ids and numbers only).
      captureProblem(
        'ledger.reconcile: cached balances do not match their ledger',
        {
          problem: 'ledger.mismatch',
          jobId: job.id,
          orgId: job.organizationId,
          count: mismatches.length,
        },
        { mismatches: mismatches.slice(0, LOGGED) },
      );
    } else {
      log.info('ledger.reconcile: every cached balance matches its ledger');
    }
  };
}
