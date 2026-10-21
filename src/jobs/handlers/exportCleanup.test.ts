import type { SupabaseClient } from '@supabase/supabase-js';
import pino from 'pino';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Job } from '../types';

const storage = vi.hoisted(() => ({ removeObject: vi.fn() }));
vi.mock('../../services/storage.service', () => storage);

import { exportCleanup } from './exportCleanup';

const ORG = '22222222-2222-4222-8222-222222222222';
const F1 = '55555555-5555-4555-8555-555555555551';
const F2 = '55555555-5555-4555-8555-555555555552';
const job = (over: Partial<Job> = {}): Job => ({
  id: '11111111-1111-4111-8111-111111111111',
  organizationId: ORG,
  type: 'export.cleanup',
  payload: {},
  attempt: 1,
  maxAttempts: 3,
  ...over,
});

function setup(listed: unknown) {
  const rpc = vi.fn(async (fn: string) =>
    fn === 'jobs_export_cleanup_list' ? { data: listed, error: null } : { data: 1, error: null },
  );
  return {
    rpc,
    handler: exportCleanup({ rpc } as unknown as SupabaseClient),
    log: pino({ level: 'silent' }),
  };
}

beforeEach(() => storage.removeObject.mockReset().mockResolvedValue(true));

describe('export.cleanup job (M03)', () => {
  it('removes the old zips from storage and marks their rows', async () => {
    const { handler, rpc, log } = setup([
      { file_id: F1, path: `${ORG}/export/2026/10/a.zip` },
      { file_id: F2, path: `${ORG}/export/2026/10/b.zip` },
    ]);
    await handler(job(), log);
    expect(storage.removeObject).toHaveBeenCalledTimes(2);
    expect(rpc).toHaveBeenCalledWith('jobs_export_cleanup_list', { p_org: ORG, p_keep_days: 7 });
    expect(rpc).toHaveBeenCalledWith('jobs_export_cleanup_done', {
      p_org: ORG,
      p_file_ids: [F1, F2],
    });
  });

  it('marks only the objects that were really removed', async () => {
    storage.removeObject.mockResolvedValueOnce(false).mockResolvedValueOnce(true);
    const { handler, rpc, log } = setup([
      { file_id: F1, path: `${ORG}/export/a.zip` },
      { file_id: F2, path: `${ORG}/export/b.zip` },
    ]);
    await handler(job(), log);
    expect(rpc).toHaveBeenCalledWith('jobs_export_cleanup_done', { p_org: ORG, p_file_ids: [F2] });
  });

  it('never deletes a path outside the shop', async () => {
    const { handler, rpc, log } = setup([{ file_id: F1, path: 'other-shop/export/a.zip' }]);
    await handler(job(), log);
    expect(storage.removeObject).not.toHaveBeenCalled();
    expect(rpc).not.toHaveBeenCalledWith('jobs_export_cleanup_done', expect.anything());
  });

  it('does nothing when no zip is old enough', async () => {
    const { handler, rpc, log } = setup([]);
    await handler(job(), log);
    expect(rpc).toHaveBeenCalledTimes(1);
  });
});
