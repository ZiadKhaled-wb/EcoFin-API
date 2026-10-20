// server/src/jobs/handlers/dayCheck.ts
//
// Daily 'day.check' (K04, D84): for every active branch of the shop, checks yesterday (and the
// closed days of the last 7 days for drift) with the same computation as the day close, and stores
// what it found in day_checks for the dashboard. It never closes or changes a day. Findings are not
// failures: retrying wouldn't change them, so the job succeeds and logs them (a broken balance, a
// document without its ledger row or a changed closed day at error level, for the Q02 alert).
// Running it twice the same night changes nothing (the audit row is written when a finding changes).

import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { captureProblem } from '../../utils/monitoring';
import type { JobHandler } from '../types';

const DayCheckResult = z.object({
  checked: z.number().int(),
  with_issues: z.number().int(),
  drift: z.number().int(),
  found: z.array(
    z.object({
      branch_id: z.string().uuid(),
      business_date: z.string(),
      critical: z.boolean(),
      codes: z.array(z.string()).nullable(),
    }),
  ),
});

export function dayCheck(db: SupabaseClient): JobHandler {
  return async (job, log) => {
    if (!job.organizationId) throw new Error('day.check needs a shop');
    const { data, error } = await db.rpc('jobs_day_check', {
      p_organization_id: job.organizationId,
    });
    if (error) throw new Error(`jobs_day_check failed: ${error.message}`);
    const result = DayCheckResult.parse(data);
    const critical = result.found.filter((f) => f.critical);
    if (critical.length > 0) {
      log.error(
        { checked: result.checked, drift: result.drift, critical },
        'day.check: a balance, a document or a closed day does not add up',
      );
      // Q02 (D35): alert through the error tracker (ids, dates and codes only).
      captureProblem(
        'day.check: a balance, a document or a closed day does not add up',
        { problem: 'day.check', jobId: job.id, orgId: job.organizationId, count: critical.length },
        { found: critical },
      );
    } else if (result.with_issues > 0) {
      log.warn({ checked: result.checked, found: result.found }, 'day.check: days with warnings');
    } else {
      log.info({ checked: result.checked }, 'day.check: nothing to report');
    }
  };
}
