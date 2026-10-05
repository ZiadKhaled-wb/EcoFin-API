// server/src/jobs/types.ts
//
// F13 background jobs (D34). The queue is public.jobs; the worker reaches it through the
// service-role functions of migration 20261003130000_f13_jobs.sql (see store.ts).

import type { Logger } from 'pino';

/** A claimed job, as the worker sees it. */
export interface Job {
  id: string;
  /** NULL for platform jobs. */
  organizationId: string | null;
  type: string;
  payload: Record<string, unknown>;
  /** This attempt's number (1 = first try). */
  attempt: number;
  maxAttempts: number;
}

/** Does the work. Throw to fail the attempt: the worker retries it later, then marks it dead. */
export type JobHandler = (job: Job, log: Logger) => Promise<void>;

/** A job queued once per shop per local day, from `localTime` (HH:MM, shop time zone) on. */
export interface DailyJob {
  type: string;
  localTime: string;
  maxAttempts?: number;
}

export type FailedStatus = 'failed' | 'dead';

/** The queue operations the worker needs (store.ts implements them on Supabase). */
export interface JobStore {
  /** Queues today's run for every shop that is due; returns how many were queued. */
  enqueueDaily(type: string, localTime: string, maxAttempts: number): Promise<number>;
  /** Takes up to `limit` due jobs of these types for this worker. */
  claim(workerId: string, types: readonly string[], limit: number): Promise<Job[]>;
  /** false when this worker no longer holds the job (it was taken over after a stall). */
  succeed(jobId: string, workerId: string): Promise<boolean>;
  /** 'failed' (retried after `retryInSeconds`) or 'dead'; null when this worker lost the job. */
  fail(
    jobId: string,
    workerId: string,
    error: string,
    retryInSeconds: number,
  ): Promise<FailedStatus | null>;
}
