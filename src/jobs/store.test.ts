import type { SupabaseClient } from '@supabase/supabase-js';
import { describe, expect, it, vi } from 'vitest';
import { supabaseJobStore } from './store';

function store(data: unknown, error: { message: string } | null = null) {
  const rpc = vi.fn().mockResolvedValue({ data, error });
  return { s: supabaseJobStore({ rpc } as unknown as SupabaseClient), rpc };
}

const row = {
  id: '11111111-1111-4111-8111-111111111111',
  organization_id: null,
  job_type: 'test.work',
  payload: { a: 1 },
  attempts: 2,
  max_attempts: 5,
  status: 'running',
  locked_by: 'w',
};

describe('supabaseJobStore', () => {
  it('claim passes the worker, its job types and the limit, and maps the rows', async () => {
    const { s, rpc } = store([row]);
    await expect(s.claim('w', ['test.work'], 10)).resolves.toEqual([
      {
        id: row.id,
        organizationId: null,
        type: 'test.work',
        payload: { a: 1 },
        attempt: 2,
        maxAttempts: 5,
      },
    ]);
    expect(rpc).toHaveBeenCalledWith('jobs_claim', {
      p_worker: 'w',
      p_types: ['test.work'],
      p_limit: 10,
    });
  });

  it('fail sends the wait as a Postgres interval and returns the new status', async () => {
    const { s, rpc } = store('dead');
    await expect(s.fail(row.id, 'w', 'boom', 119.6)).resolves.toBe('dead');
    expect(rpc).toHaveBeenCalledWith('jobs_fail', {
      p_job_id: row.id,
      p_worker: 'w',
      p_error: 'boom',
      p_retry_in: '120 seconds',
    });
  });

  it('fail returns null when the worker no longer holds the job; a negative wait becomes 0', async () => {
    const { s, rpc } = store(null);
    await expect(s.fail(row.id, 'w', 'boom', -5)).resolves.toBeNull();
    expect(rpc).toHaveBeenCalledWith(
      'jobs_fail',
      expect.objectContaining({ p_retry_in: '0 seconds' }),
    );
  });

  it('enqueueDaily and succeed parse their results', async () => {
    await expect(store(3).s.enqueueDaily('test.work', '03:00', 5)).resolves.toBe(3);
    await expect(store(false).s.succeed(row.id, 'w')).resolves.toBe(false);
  });

  it('a database error names the function, never the arguments', async () => {
    const { s } = store(null, { message: 'permission denied' });
    await expect(s.claim('w', ['test.work'], 10)).rejects.toThrow(
      'jobs_claim failed: permission denied',
    );
  });

  it('an unexpected row shape is an error, not a job run with bad data', async () => {
    const { s } = store([{ ...row, id: 'not-a-uuid' }]);
    await expect(s.claim('w', ['test.work'], 10)).rejects.toThrow();
  });
});
