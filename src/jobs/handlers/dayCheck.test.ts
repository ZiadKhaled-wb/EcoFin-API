import { Writable } from 'node:stream';
import type { SupabaseClient } from '@supabase/supabase-js';
import pino from 'pino';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Job } from '../types';
const captureProblem = vi.hoisted(() => vi.fn());
vi.mock('../../utils/monitoring', () => ({ captureProblem }));

import { DAILY_JOBS } from '../registry';
import { dayCheck } from './dayCheck';

const ORG = '22222222-2222-4222-8222-222222222222';
const BRANCH = '33333333-3333-4333-8333-333333333333';

function setup(result: { data: unknown; error: { message: string } | null }) {
  const lines: { level: number; msg: string }[] = [];
  const stream = new Writable({
    write(chunk: Buffer, _enc, done) {
      lines.push(JSON.parse(chunk.toString()) as { level: number; msg: string });
      done();
    },
  });
  const rpc = vi.fn().mockResolvedValue(result);
  const db = { rpc } as unknown as SupabaseClient;
  return { handler: dayCheck(db), rpc, lines, log: pino({ level: 'trace' }, stream) };
}

const job = (organizationId: string | null = ORG): Job => ({
  id: '11111111-1111-4111-8111-111111111111',
  organizationId,
  type: 'day.check',
  payload: {},
  attempt: 1,
  maxAttempts: 5,
});

const found = (critical: boolean) => ({
  branch_id: BRANCH,
  business_date: '2026-10-19',
  critical,
  codes: critical ? ['LEDGER_MISMATCH'] : ['ETA_NOT_ACCEPTED'],
});

describe('day.check job (K04)', () => {
  beforeEach(() => captureProblem.mockReset());

  it('runs daily at 03:30 shop time, after ledger.reconcile', () => {
    expect(DAILY_JOBS).toContainEqual({ type: 'day.check', localTime: '03:30' });
  });

  it('calls jobs_day_check for the job shop and logs a quiet night at info', async () => {
    const { handler, rpc, lines, log } = setup({
      data: { checked: 2, with_issues: 0, drift: 0, found: [] },
      error: null,
    });
    await handler(job(), log);
    expect(rpc).toHaveBeenCalledWith('jobs_day_check', { p_organization_id: ORG });
    expect(lines.at(-1)?.level).toBe(30);
    expect(captureProblem).not.toHaveBeenCalled();
  });

  it('warnings only: logged at warn, no alert', async () => {
    const { handler, lines, log } = setup({
      data: { checked: 1, with_issues: 1, drift: 0, found: [found(false)] },
      error: null,
    });
    await handler(job(), log);
    expect(lines.at(-1)?.level).toBe(40);
    expect(captureProblem).not.toHaveBeenCalled();
  });

  it('a broken balance or drift: error log and one alert, and the job still succeeds', async () => {
    const { handler, lines, log } = setup({
      data: { checked: 1, with_issues: 1, drift: 1, found: [found(true)] },
      error: null,
    });
    await expect(handler(job(), log)).resolves.toBeUndefined();
    expect(lines.at(-1)?.level).toBe(50);
    expect(captureProblem).toHaveBeenCalledTimes(1);
    expect(captureProblem.mock.calls[0]?.[1]).toMatchObject({ problem: 'day.check', count: 1 });
  });

  it('fails the attempt on a database error or without a shop', async () => {
    const failing = setup({ data: null, error: { message: 'boom' } });
    await expect(failing.handler(job(), failing.log)).rejects.toThrow('jobs_day_check failed');
    const noShop = setup({ data: null, error: null });
    await expect(noShop.handler(job(null), noShop.log)).rejects.toThrow('needs a shop');
    expect(noShop.rpc).not.toHaveBeenCalled();
  });
});
