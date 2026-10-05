import { Writable } from 'node:stream';
import pino from 'pino';
import { describe, expect, it, vi } from 'vitest';
import type { FailedStatus, Job, JobHandler, JobStore } from './types';
import { JobWorker, defaultRetryDelay } from './worker';

interface Line {
  level: number;
  msg: string;
  [key: string]: unknown;
}

/** A pino logger whose JSON lines land in `lines`. */
function captureLogger() {
  const lines: Line[] = [];
  const stream = new Writable({
    write(chunk: Buffer, _enc, done) {
      lines.push(JSON.parse(chunk.toString()) as Line);
      done();
    },
  });
  return { logger: pino({ level: 'trace' }, stream), lines };
}

const job = (overrides: Partial<Job> = {}): Job => ({
  id: '11111111-1111-4111-8111-111111111111',
  organizationId: '22222222-2222-4222-8222-222222222222',
  type: 'test.work',
  payload: {},
  attempt: 1,
  maxAttempts: 3,
  ...overrides,
});

/** An in-memory store: `due` is handed out once by claim(). */
function fakeStore(due: Job[] = [], failStatus: FailedStatus | null = 'failed') {
  const store = {
    enqueueDaily: vi.fn<JobStore['enqueueDaily']>().mockResolvedValue(0),
    claim: vi.fn<JobStore['claim']>().mockImplementation(() => Promise.resolve(due.splice(0))),
    succeed: vi.fn<JobStore['succeed']>().mockResolvedValue(true),
    fail: vi.fn<JobStore['fail']>().mockResolvedValue(failStatus),
  };
  return store;
}

function worker(store: JobStore, handlers: Record<string, JobHandler>, extra = {}) {
  const { logger, lines } = captureLogger();
  const w = new JobWorker({ store, handlers, logger, workerId: 'w-test', ...extra });
  return { w, lines };
}

describe('JobWorker.tick', () => {
  it('runs a claimed job and marks it succeeded', async () => {
    const store = fakeStore([job()]);
    const handler = vi.fn<JobHandler>().mockResolvedValue(undefined);
    const { w, lines } = worker(store, { 'test.work': handler });

    await expect(w.tick()).resolves.toEqual({ queued: 0, succeeded: 1, failed: 0, dead: 0 });
    expect(store.claim).toHaveBeenCalledWith('w-test', ['test.work'], 10);
    expect(handler).toHaveBeenCalledWith(
      expect.objectContaining({ id: job().id }),
      expect.anything(),
    );
    expect(store.succeed).toHaveBeenCalledWith(job().id, 'w-test');
    expect(lines.find((l) => l.msg === 'job succeeded')).toMatchObject({
      jobId: job().id,
      jobType: 'test.work',
      orgId: job().organizationId,
      attempt: 1,
      worker: 'w-test',
    });
  });

  it('a failing job is retried after the backoff for that attempt', async () => {
    const store = fakeStore([job({ attempt: 2 })], 'failed');
    const { w, lines } = worker(store, {
      'test.work': () => Promise.reject(new Error('ETA is down')),
    });

    await expect(w.tick()).resolves.toMatchObject({ failed: 1, dead: 0 });
    expect(store.fail).toHaveBeenCalledWith(job().id, 'w-test', 'Error: ETA is down', 120);
    expect(store.succeed).not.toHaveBeenCalled();
    const warn = lines.find((l) => l.msg === 'job failed: will retry');
    expect(warn).toMatchObject({ level: 40, retryInSeconds: 120, attempt: 2 });
  });

  it('the last failed attempt lands in the failed list and is logged as an error', async () => {
    const store = fakeStore([job({ attempt: 3 })], 'dead');
    const { w, lines } = worker(store, { 'test.work': () => Promise.reject(new Error('boom')) });

    await expect(w.tick()).resolves.toMatchObject({ failed: 0, dead: 1 });
    expect(lines.find((l) => l.msg.includes('moved to the failed list'))).toMatchObject({
      level: 50,
      jobId: job().id,
    });
  });

  it('a rejection that is not an Error is still recorded as the failure', async () => {
    const store = fakeStore([job()]);
    // Library code can reject with a plain string; the worker must still record it.
    const { w } = worker(store, { 'test.work': () => Promise.reject('plain string') });
    await w.tick();
    expect(store.fail).toHaveBeenCalledWith(job().id, 'w-test', 'plain string', 60);
  });

  it('a job whose type has no handler fails instead of being skipped', async () => {
    const store = fakeStore([job({ type: 'test.unknown' })]);
    const { w } = worker(store, { 'test.work': () => Promise.resolve() });
    await w.tick();
    expect(store.fail).toHaveBeenCalledWith(
      job().id,
      'w-test',
      'Error: no handler for job type test.unknown',
      60,
    );
  });

  it('queues the daily jobs before claiming, and a queueing error does not stop the tick', async () => {
    const store = fakeStore([job()]);
    store.enqueueDaily.mockResolvedValueOnce(3).mockRejectedValueOnce(new Error('db down'));
    const { w, lines } = worker(
      store,
      { 'test.work': () => Promise.resolve(), 'test.other': () => Promise.resolve() },
      {
        daily: [
          { type: 'test.work', localTime: '03:00' },
          { type: 'test.other', localTime: '04:30', maxAttempts: 2 },
        ],
      },
    );

    await expect(w.tick()).resolves.toMatchObject({ queued: 3, succeeded: 1 });
    expect(store.enqueueDaily).toHaveBeenNthCalledWith(1, 'test.work', '03:00', 5);
    expect(store.enqueueDaily).toHaveBeenNthCalledWith(2, 'test.other', '04:30', 2);
    expect(lines.find((l) => l.msg === 'could not queue daily job')).toMatchObject({
      level: 50,
      jobType: 'test.other',
    });
  });

  it('a daily job without a handler is a startup error', () => {
    expect(() =>
      worker(fakeStore(), {}, { daily: [{ type: 'test.x', localTime: '01:00' }] }),
    ).toThrow('daily job test.x has no handler');
  });

  it('a claim error is logged and the tick ends quietly', async () => {
    const store = fakeStore();
    store.claim.mockRejectedValue(new Error('network'));
    const { w, lines } = worker(store, { 'test.work': () => Promise.resolve() });
    await expect(w.tick()).resolves.toEqual({ queued: 0, succeeded: 0, failed: 0, dead: 0 });
    expect(lines.some((l) => l.msg === 'could not claim jobs')).toBe(true);
  });

  it('a job that another worker took over is not reported as done by this one', async () => {
    const store = fakeStore([job()]);
    store.succeed.mockResolvedValue(false);
    const { w, lines } = worker(store, { 'test.work': () => Promise.resolve() });
    await w.tick();
    expect(lines.some((l) => l.msg === 'job finished, but another worker had taken it over')).toBe(
      true,
    );
    expect(lines.some((l) => l.msg === 'job succeeded')).toBe(false);
  });

  it('overlapping ticks share one run', async () => {
    const store = fakeStore([job()]);
    let release: () => void = () => undefined;
    const handler = vi.fn<JobHandler>(() => new Promise<void>((r) => (release = r)));
    const { w } = worker(store, { 'test.work': handler });
    const first = w.tick();
    const second = w.tick();
    expect(second).toBe(first);
    await vi.waitFor(() => expect(handler).toHaveBeenCalledTimes(1));
    release();
    await first;
    expect(store.claim).toHaveBeenCalledTimes(1);
  });

  it('stop() waits for the job in progress', async () => {
    const store = fakeStore([job()]);
    let release: () => void = () => undefined;
    const { w } = worker(
      store,
      { 'test.work': () => new Promise<void>((r) => (release = r)) },
      { pollSeconds: 3600 },
    );
    w.start();
    await vi.waitFor(() => expect(store.claim).toHaveBeenCalled());
    let stopped = false;
    const stopping = w.stop().then(() => (stopped = true));
    await Promise.resolve();
    expect(stopped).toBe(false);
    release();
    await stopping;
    expect(store.succeed).toHaveBeenCalledTimes(1);
  });
});

describe('defaultRetryDelay', () => {
  it('doubles from 1 minute and stops at 1 hour', () => {
    expect([1, 2, 3, 4, 7, 8, 20].map(defaultRetryDelay)).toEqual([
      60, 120, 240, 480, 3600, 3600, 3600,
    ]);
  });
});
