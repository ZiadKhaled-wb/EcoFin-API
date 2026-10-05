// server/src/jobs/store.ts
//
// The job queue on Supabase: service-role RPCs from migration 20261003130000_f13_jobs.sql. Rows
// are checked with zod, so a DB change that breaks the shape fails loudly instead of running a
// job with wrong data.

import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import type { FailedStatus, Job, JobStore } from './types';

const JobRow = z.object({
  id: z.string().uuid(),
  organization_id: z.string().uuid().nullable(),
  job_type: z.string(),
  payload: z.record(z.unknown()),
  attempts: z.number().int(),
  max_attempts: z.number().int(),
});

/** One RPC; any database error becomes an Error naming the function (never the arguments). */
async function call(
  db: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn} failed: ${error.message}`);
  return data;
}

export function supabaseJobStore(db: SupabaseClient): JobStore {
  return {
    async enqueueDaily(type, localTime, maxAttempts) {
      const data = await call(db, 'jobs_enqueue_daily', {
        p_job_type: type,
        p_local_time: localTime,
        p_max_attempts: maxAttempts,
      });
      return z.number().int().parse(data);
    },

    async claim(workerId, types, limit): Promise<Job[]> {
      const data = await call(db, 'jobs_claim', {
        p_worker: workerId,
        p_types: types,
        p_limit: limit,
      });
      return z
        .array(JobRow)
        .parse(data)
        .map((row) => ({
          id: row.id,
          organizationId: row.organization_id,
          type: row.job_type,
          payload: row.payload,
          attempt: row.attempts,
          maxAttempts: row.max_attempts,
        }));
    },

    async succeed(jobId, workerId) {
      const data = await call(db, 'jobs_succeed', { p_job_id: jobId, p_worker: workerId });
      return z.boolean().parse(data);
    },

    async fail(jobId, workerId, error, retryInSeconds): Promise<FailedStatus | null> {
      const data = await call(db, 'jobs_fail', {
        p_job_id: jobId,
        p_worker: workerId,
        p_error: error,
        p_retry_in: `${Math.max(0, Math.round(retryInSeconds))} seconds`,
      });
      return z.enum(['failed', 'dead']).nullable().parse(data);
    },
  };
}
