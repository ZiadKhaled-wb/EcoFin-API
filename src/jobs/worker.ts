// server/src/jobs/worker.ts
//
// F13 job worker (D34). Every tick:
//   1. asks the database to queue today's run of each daily job for every shop that is due in its
//      own time zone (the database makes this once per shop per day, however many servers tick);
//   2. claims due jobs of the types it has handlers for (no two workers get the same job);
//   3. runs each one: success -> succeeded; an error -> retried after a growing wait, and after the
//      last attempt -> 'dead' (the failed list).
// Every run, retry and dead job is one structured log line (job id, type, shop, attempt).
// Safe to run on several API instances at once.

import { hostname } from 'node:os';
import { randomUUID } from 'node:crypto';
import type { Logger } from 'pino';
import { captureProblem } from '../utils/monitoring';
import type { DailyJob, Job, JobHandler, JobStore } from './types';

/** Wait before retry n (n = the attempt that just failed): 1, 2, 4, 8 ... minutes, at most 1 hour. */
export function defaultRetryDelay(attempt: number): number {
  return Math.min(60 * 2 ** Math.max(0, attempt - 1), 3600);
}

export interface JobWorkerOptions {
  store: JobStore;
  handlers: Readonly<Record<string, JobHandler>>;
  daily?: readonly DailyJob[];
  logger: Logger;
  /** Unique per process; shows up in jobs.locked_by. */
  workerId?: string;
  /** Jobs claimed per tick. */
  batchSize?: number;
  pollSeconds?: number;
  retryDelay?: (attempt: number) => number;
}

export interface TickResult {
  queued: number;
  succeeded: number;
  failed: number;
  dead: number;
}

/** Error text kept on the job: the message only, never a stack or the payload. */
function errorText(err: unknown): string {
  if (err instanceof Error) return `${err.name}: ${err.message}`;
  return typeof err === 'string' ? err : 'non-error thrown';
}

export class JobWorker {
  readonly workerId: string;
  private readonly store: JobStore;
  private readonly handlers: Readonly<Record<string, JobHandler>>;
  private readonly types: string[];
  private readonly daily: readonly DailyJob[];
  private readonly log: Logger;
  private readonly batchSize: number;
  private readonly pollMs: number;
  private readonly retryDelay: (attempt: number) => number;
  private timer: NodeJS.Timeout | undefined;
  private current: Promise<TickResult> | undefined;

  constructor(options: JobWorkerOptions) {
    this.store = options.store;
    this.handlers = options.handlers;
    this.types = Object.keys(options.handlers);
    this.daily = options.daily ?? [];
    this.workerId = options.workerId ?? `${hostname()}/${process.pid}/${randomUUID().slice(0, 8)}`;
    this.log = options.logger.child({ component: 'jobs', worker: this.workerId });
    this.batchSize = options.batchSize ?? 10;
    this.pollMs = (options.pollSeconds ?? 30) * 1000;
    this.retryDelay = options.retryDelay ?? defaultRetryDelay;
    for (const job of this.daily) {
      if (!this.handlers[job.type]) throw new Error(`daily job ${job.type} has no handler`);
    }
  }

  /** One pass. A tick that's still running is shared, never run twice at the same time. */
  tick(): Promise<TickResult> {
    this.current ??= this.runTick().finally(() => {
      this.current = undefined;
    });
    return this.current;
  }

  /** Ticks now and then every `pollSeconds` until stop(). */
  start(): void {
    if (this.timer) return;
    this.log.info({ types: this.types, pollMs: this.pollMs }, 'job worker started');
    const run = () => void this.tick();
    run();
    this.timer = setInterval(run, this.pollMs);
    this.timer.unref();
  }

  /** Stops ticking and waits for the current tick to finish. */
  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    await this.current;
    this.log.info('job worker stopped');
  }

  private async runTick(): Promise<TickResult> {
    const result: TickResult = { queued: 0, succeeded: 0, failed: 0, dead: 0 };
    for (const job of this.daily) {
      try {
        result.queued += await this.store.enqueueDaily(
          job.type,
          job.localTime,
          job.maxAttempts ?? 5,
        );
      } catch (err) {
        this.log.error({ err, jobType: job.type }, 'could not queue daily job');
      }
    }
    if (this.types.length === 0) return result;

    let jobs: Job[];
    try {
      jobs = await this.store.claim(this.workerId, this.types, this.batchSize);
    } catch (err) {
      this.log.error({ err }, 'could not claim jobs');
      return result;
    }
    for (const job of jobs) {
      const outcome = await this.run(job);
      result[outcome] += 1;
    }
    return result;
  }

  private async run(job: Job): Promise<'succeeded' | 'failed' | 'dead'> {
    const log = this.log.child({
      jobId: job.id,
      jobType: job.type,
      orgId: job.organizationId,
      attempt: job.attempt,
      maxAttempts: job.maxAttempts,
    });
    const handler = this.handlers[job.type];
    const started = Date.now();
    try {
      if (!handler) throw new Error(`no handler for job type ${job.type}`);
      await handler(job, log);
    } catch (err) {
      return this.failed(job, log, err, Date.now() - started);
    }
    try {
      const held = await this.store.succeed(job.id, this.workerId);
      if (held) log.info({ ms: Date.now() - started }, 'job succeeded');
      else log.warn('job finished, but another worker had taken it over');
    } catch (err) {
      // The work is done; the job stays 'running' and is retried after 15 minutes, so handlers
      // must be safe to run again (they are: every job is idempotent by design, D34).
      log.error({ err }, 'job succeeded, but could not be marked done');
    }
    return 'succeeded';
  }

  private async failed(
    job: Job,
    log: Logger,
    err: unknown,
    ms: number,
  ): Promise<'failed' | 'dead'> {
    const retryIn = this.retryDelay(job.attempt);
    let status: 'failed' | 'dead' | null;
    try {
      status = await this.store.fail(job.id, this.workerId, errorText(err), retryIn);
    } catch (storeErr) {
      log.error({ err, storeErr }, 'job failed, and the failure could not be recorded');
      return 'failed';
    }
    if (status === 'dead') {
      log.error({ err, ms }, 'job failed for the last time: moved to the failed list');
      // Q02 (D35): a dead job alerts through the error tracker.
      captureProblem(err, {
        problem: 'job.dead',
        jobId: job.id,
        jobType: job.type,
        orgId: job.organizationId,
        attempts: job.attempt,
        worker: this.workerId,
      });
      return 'dead';
    }
    if (status === null) log.warn({ err, ms }, 'job failed, but another worker had taken it over');
    else log.warn({ err, ms, retryInSeconds: retryIn }, 'job failed: will retry');
    return 'failed';
  }
}
