import { Writable } from 'node:stream';
import type { SupabaseClient } from '@supabase/supabase-js';
import pino from 'pino';
import { describe, expect, it, vi } from 'vitest';
import { DAILY_JOBS } from '../registry';
import type { Job } from '../types';
import { overdueCheck } from './overdueCheck';

const ORG = '22222222-2222-4222-8222-222222222222';

function setup(result: { data: unknown; error: { message: string } | null }) {
  const lines: { level: number; msg: string; skipped?: string; bans?: number }[] = [];
  const stream = new Writable({
    write(chunk: Buffer, _enc, done) {
      lines.push(JSON.parse(chunk.toString()) as { level: number; msg: string });
      done();
    },
  });
  const rpc = vi.fn().mockResolvedValue(result);
  const db = { rpc } as unknown as SupabaseClient;
  return { handler: overdueCheck(db), rpc, lines, log: pino({ level: 'trace' }, stream) };
}

const job = (organizationId: string | null = ORG): Job => ({
  id: '11111111-1111-4111-8111-111111111111',
  organizationId,
  type: 'installments.overdue',
  payload: {},
  attempt: 1,
  maxAttempts: 5,
});

describe('installments.overdue job (N04)', () => {
  it('is a daily job at 00:30 shop time', () => {
    expect(DAILY_JOBS).toContainEqual({ type: 'installments.overdue', localTime: '00:30' });
  });

  it('runs the shop’s check and logs the counts', async () => {
    const counts = {
      business_date: '2026-10-17',
      warnings_created: 3,
      warnings_resolved: 1,
      bans: 1,
      customers_blocked: 1,
      legal_referrals: 0,
    };
    const { handler, rpc, lines, log } = setup({ data: counts, error: null });
    await handler(job(), log);
    expect(rpc).toHaveBeenCalledWith('jobs_overdue_run', { p_organization_id: ORG });
    expect(lines.at(-1)).toMatchObject({ msg: 'installments.overdue: done', bans: 1 });
  });

  it('logs a skipped shop (no installments, or expired) without failing', async () => {
    const { handler, lines, log } = setup({ data: { skipped: 'expired' }, error: null });
    await handler(job(), log);
    expect(lines.at(-1)).toMatchObject({
      msg: 'installments.overdue: skipped',
      skipped: 'expired',
    });
  });

  it('fails the attempt on a database error (the worker retries; the check is safe to repeat)', async () => {
    const { handler, log } = setup({ data: null, error: { message: 'boom' } });
    await expect(handler(job(), log)).rejects.toThrow('jobs_overdue_run failed: boom');
  });

  it('needs a shop', async () => {
    const { handler, log } = setup({ data: null, error: null });
    await expect(handler(job(null), log)).rejects.toThrow('installments.overdue needs a shop');
  });
});
