import { Writable } from 'node:stream';
import type { SupabaseClient } from '@supabase/supabase-js';
import pino from 'pino';
import { describe, expect, it, vi } from 'vitest';
import type { Job } from '../types';
const captureProblem = vi.hoisted(() => vi.fn());
vi.mock('../../utils/monitoring', () => ({ captureProblem }));

import { ledgerReconcile } from './ledgerReconcile';

const ORG = '22222222-2222-4222-8222-222222222222';

function setup(result: { data: unknown; error: { message: string } | null }) {
  const lines: { level: number; msg: string; count?: number }[] = [];
  const stream = new Writable({
    write(chunk: Buffer, _enc, done) {
      lines.push(JSON.parse(chunk.toString()) as { level: number; msg: string });
      done();
    },
  });
  const rpc = vi.fn().mockResolvedValue(result);
  const db = { rpc } as unknown as SupabaseClient;
  return { handler: ledgerReconcile(db), rpc, lines, log: pino({ level: 'trace' }, stream) };
}

const job = (organizationId: string | null = ORG): Job => ({
  id: '11111111-1111-4111-8111-111111111111',
  organizationId,
  type: 'ledger.reconcile',
  payload: { businessDate: '2026-10-05' },
  attempt: 1,
  maxAttempts: 5,
});

const mismatch = {
  ledger: 'cash',
  organization_id: ORG,
  subject_id: '33333333-3333-4333-8333-333333333333',
  branch_id: null,
  detail: null,
  cached: 100.01,
  from_ledger: 100,
};

describe('ledger.reconcile job', () => {
  it("checks the job's shop and logs info when everything matches", async () => {
    const { handler, rpc, lines, log } = setup({ data: [], error: null });
    await handler(job(), log);
    expect(rpc).toHaveBeenCalledWith('jobs_ledger_mismatches', { p_organization_id: ORG });
    expect(lines).toEqual([
      expect.objectContaining({ level: 30, msg: expect.stringContaining('matches') }),
    ]);
  });

  it('a mismatch is logged as an error with the count, and the job still succeeds', async () => {
    const { handler, lines, log } = setup({ data: [mismatch, mismatch], error: null });
    await expect(handler(job(), log)).resolves.toBeUndefined();
    expect(lines[0]).toMatchObject({ level: 50, count: 2 });
    expect(captureProblem).toHaveBeenCalledWith(
      'ledger.reconcile: cached balances do not match their ledger',
      expect.objectContaining({ problem: 'ledger.mismatch', orgId: ORG, count: 2 }),
      {
        mismatches: [
          expect.objectContaining({ ledger: 'cash', cached: 100.01 }),
          expect.anything(),
        ],
      },
    );
  });

  it('a database error fails the attempt (so it is retried)', async () => {
    const { handler, log } = setup({ data: null, error: { message: 'timeout' } });
    await expect(handler(job(), log)).rejects.toThrow('jobs_ledger_mismatches failed: timeout');
  });

  it('a platform job without a shop is refused', async () => {
    const { handler, rpc, log } = setup({ data: [], error: null });
    await expect(handler(job(null), log)).rejects.toThrow('needs a shop');
    expect(rpc).not.toHaveBeenCalled();
  });

  it('rows outside the expected shape fail loudly', async () => {
    const { handler, log } = setup({ data: [{ ledger: 'cash' }], error: null });
    await expect(handler(job(), log)).rejects.toThrow();
  });
});
