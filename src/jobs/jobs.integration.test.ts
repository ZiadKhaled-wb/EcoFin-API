// F13 against local Supabase (D34): the two "Done when" checks, through the real service-role
// functions and PostgREST. Skipped unless RUN_INTEGRATION=1 (env: see src/routes/auth.integration.test.ts).
//   1. A failing job is retried, then lands in the failed list ('dead').
//   2. A daily job runs once per shop per day even with two server instances: two workers, each
//      with its own Supabase client (separate connections, nothing shared in memory), tick at the
//      same time again and again.
// Job types are unique per run, and every row this file creates is deleted afterwards.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import pino from 'pino';
import { getEnv } from '../utils/env';
import { ledgerReconcile } from './handlers/ledgerReconcile';
import { supabaseJobStore } from './store';
import type { Job, JobHandler } from './types';
import { JobWorker } from './worker';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const STAMP = Date.now();
const FAILING = `test.f13_fails_${STAMP}`;
const DAILY = `test.f13_daily_${STAMP}`;
const SHOP_ONE = 'd1000000-0000-0000-0000-000000000001';
const silent = pino({ level: 'silent' });

describe.skipIf(!RUN)('F13 jobs against local Supabase', () => {
  let service: SupabaseClient;
  const newClient = () => {
    const env = getEnv();
    return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  };

  beforeAll(() => {
    service = newClient();
  });

  afterAll(async () => {
    await service.from('jobs').delete().in('job_type', [FAILING, DAILY]);
  });

  it('a failing job is retried, then lands in the failed list', async () => {
    const { data: inserted, error } = await service
      .from('jobs')
      .insert({ job_type: FAILING, organization_id: SHOP_ONE, max_attempts: 3 })
      .select('id')
      .single();
    expect(error).toBeNull();
    const id = (inserted as { id: string }).id;

    let calls = 0;
    const w = new JobWorker({
      store: supabaseJobStore(newClient()),
      handlers: {
        [FAILING]: () => {
          calls += 1;
          return Promise.reject(new Error(`ETA unreachable (try ${calls})`));
        },
      },
      logger: silent,
      workerId: `f13-it-${STAMP}`,
      retryDelay: () => 0, // retry at once so the test doesn't wait
    });

    const row = async () => {
      const { data } = await service
        .from('jobs')
        .select('status, attempts, last_error, finished_at')
        .eq('id', id)
        .single();
      return data as {
        status: string;
        attempts: number;
        last_error: string;
        finished_at: string | null;
      };
    };

    await expect(w.tick()).resolves.toMatchObject({ failed: 1, dead: 0 });
    expect(await row()).toMatchObject({ status: 'failed', attempts: 1, finished_at: null });
    await expect(w.tick()).resolves.toMatchObject({ failed: 1, dead: 0 });
    expect(await row()).toMatchObject({ status: 'failed', attempts: 2 });
    await expect(w.tick()).resolves.toMatchObject({ failed: 0, dead: 1 });
    expect(await row()).toMatchObject({
      status: 'dead',
      attempts: 3,
      last_error: 'Error: ETA unreachable (try 3)',
    });
    expect((await row()).finished_at).not.toBeNull();

    // The failed list: dead jobs are never claimed again.
    await expect(w.tick()).resolves.toEqual({ queued: 0, succeeded: 0, failed: 0, dead: 0 });
    expect(calls).toBe(3);
    const { data: dead } = await service
      .from('jobs')
      .select('id')
      .eq('status', 'dead')
      .eq('job_type', FAILING);
    expect(dead).toEqual([{ id }]);
  }, 30_000);

  it('a daily job runs once per shop per day with two server instances', async () => {
    const runs: { org: string | null; worker: string }[] = [];
    const makeWorker = (name: string) => {
      const handler: JobHandler = (job: Job) => {
        runs.push({ org: job.organizationId, worker: name });
        return new Promise((resolve) => setTimeout(resolve, 20)); // a little real work
      };
      return new JobWorker({
        store: supabaseJobStore(newClient()),
        handlers: { [DAILY]: handler },
        daily: [{ type: DAILY, localTime: '00:00' }], // due in every shop right now
        logger: silent,
        workerId: `${name}-${STAMP}`,
        batchSize: 2, // several claims per round, so the two instances really interleave
      });
    };
    const a = makeWorker('instance-a');
    const b = makeWorker('instance-b');

    // Tick both instances at the same time until neither finds work (at most 50 rounds).
    for (let round = 0; round < 50; round++) {
      const [ra, rb] = await Promise.all([a.tick(), b.tick()]);
      if (ra.queued + ra.succeeded + rb.queued + rb.succeeded === 0) break;
    }

    const { data: shops } = await service.from('organizations').select('id').eq('status', 'active');
    const active = (shops as { id: string }[]).map((s) => s.id).sort();
    expect(active.length).toBeGreaterThanOrEqual(2);

    // Every active shop ran exactly once, whichever instance took it.
    expect(runs.map((r) => r.org).sort()).toEqual(active);
    const { data: rows } = await service
      .from('jobs')
      .select('organization_id, status, dedupe_key, payload')
      .eq('job_type', DAILY);
    const jobs = rows as {
      organization_id: string;
      status: string;
      dedupe_key: string;
      payload: { businessDate: string };
    }[];
    expect(jobs).toHaveLength(active.length);
    expect(jobs.every((j) => j.status === 'succeeded')).toBe(true);
    expect(
      jobs.every((j) => j.dedupe_key === `${j.organization_id}/${j.payload.businessDate}`),
    ).toBe(true);

    // Later the same day, both instances keep ticking: nothing is queued or run again.
    await Promise.all([a.tick(), b.tick(), a.tick(), b.tick()]);
    expect(runs).toHaveLength(active.length);
  }, 60_000);

  it('the ledger.reconcile handler checks a seeded shop end to end', async () => {
    const handler = ledgerReconcile(newClient());
    const job: Job = {
      id: '00000000-0000-4000-8000-000000000000',
      organizationId: SHOP_ONE,
      type: 'ledger.reconcile',
      payload: {},
      attempt: 1,
      maxAttempts: 5,
    };
    await expect(handler(job, silent)).resolves.toBeUndefined();
  });

  it('app users cannot reach the job functions', async () => {
    const env = getEnv();
    const anon = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
      auth: { persistSession: false },
    });
    const { error } = await anon.rpc('jobs_claim', { p_worker: 'x', p_types: [DAILY], p_limit: 1 });
    expect(error).not.toBeNull();
  });
});
