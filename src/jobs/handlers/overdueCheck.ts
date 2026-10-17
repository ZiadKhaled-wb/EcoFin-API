// server/src/jobs/handlers/overdueCheck.ts
//
// Daily 'installments.overdue' (N04, D79): the shop's overdue check for today, in its own time
// zone. Warnings, bans and legal referrals are recorded under unique keys in SQL, so a retry after
// a crash (or the owner's manual run the same day) changes nothing. It never adds to what a
// customer owes (Islamic finance rule 4). A shop without installments or with an expired
// subscription is skipped.

import type { SupabaseClient } from '@supabase/supabase-js';
import { OverdueRunResult } from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import type { JobHandler } from '../types';

const Skipped = z.object({ skipped: z.enum(['module', 'expired']) });

export function overdueCheck(db: SupabaseClient): JobHandler {
  return async (job, log) => {
    if (!job.organizationId) throw new Error('installments.overdue needs a shop');
    const { data, error } = await db.rpc('jobs_overdue_run', {
      p_organization_id: job.organizationId,
    });
    if (error) throw new Error(`jobs_overdue_run failed: ${error.message}`);
    const skipped = Skipped.safeParse(data);
    if (skipped.success) {
      log.info({ skipped: skipped.data.skipped }, 'installments.overdue: skipped');
      return;
    }
    log.info(OverdueRunResult.parse(data), 'installments.overdue: done');
  };
}
