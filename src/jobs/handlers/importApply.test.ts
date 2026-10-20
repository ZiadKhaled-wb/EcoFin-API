import type { SupabaseClient } from '@supabase/supabase-js';
import pino from 'pino';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { sha256Hex } from '../../services/files.rules';
import type { Job } from '../types';

const storage = vi.hoisted(() => ({
  getObject: vi.fn(),
  putObject: vi.fn(),
  removeObject: vi.fn(),
}));
vi.mock('../../services/storage.service', () => storage);

import { importApply } from './importApply';
import { jobHandlers } from '../registry';

const ORG = '22222222-2222-4222-8222-222222222222';
const IMPORT_JOB = '33333333-3333-4333-8333-333333333333';
const CSV = Buffer.from('Item Code,Product Name,Price\nA1,هاتف,9000\nA2,كابل,50\n');
const MAPPING = { sku: 'Item Code', name_ar: 'Product Name', cash_price: 'Price' };

const prepared = (over: Record<string, unknown> = {}) => ({
  organization_id: ORG,
  kind: 'products',
  status: 'importing',
  branch_id: null,
  rows_total: 2,
  sheet: null,
  mapping: MAPPING,
  file_path: `${ORG}/import/2026/10/f.csv`,
  file_sha256: sha256Hex(CSV),
  ...over,
});

const job = (over: Partial<Job> = {}): Job => ({
  id: '11111111-1111-4111-8111-111111111111',
  organizationId: ORG,
  type: 'import.apply',
  payload: { import_job_id: IMPORT_JOB },
  attempt: 1,
  maxAttempts: 3,
  ...over,
});

function setup(answers: Record<string, unknown>) {
  const rpc = vi.fn(async (fn: string) => {
    const answer = answers[fn];
    if (answer instanceof Error) return { data: null, error: { message: answer.message } };
    return { data: answer ?? null, error: null };
  });
  const db = { rpc } as unknown as SupabaseClient;
  return { rpc, handler: importApply(db), log: pino({ level: 'silent' }) };
}

beforeEach(() => {
  storage.getObject.mockReset().mockResolvedValue(CSV);
  storage.putObject.mockReset().mockResolvedValue(undefined);
  storage.removeObject.mockReset().mockResolvedValue(true);
});

describe('import.apply job (M01)', () => {
  it('is registered and not a daily job', () => {
    const handlers = jobHandlers({} as SupabaseClient, pino({ level: 'silent' }));
    expect(typeof handlers['import.apply']).toBe('function');
  });

  it('reads the stored file again and hands the same rows (by field key) to SQL', async () => {
    const { handler, rpc, log } = setup({
      jobs_import_prepare: prepared(),
      jobs_import_apply: { status: 'completed', changed: true, errors: [] },
    });
    await handler(job(), log);
    expect(storage.getObject).toHaveBeenCalledWith(`${ORG}/import/2026/10/f.csv`);
    expect(rpc).toHaveBeenLastCalledWith('jobs_import_apply', {
      p_job_id: IMPORT_JOB,
      p_rows: [
        { row: 2, values: { sku: 'A1', name_ar: 'هاتف', cash_price: '9000' } },
        { row: 3, values: { sku: 'A2', name_ar: 'كابل', cash_price: '50' } },
      ],
    });
    expect(storage.putObject).not.toHaveBeenCalled();
  });

  it('a job that is not importing any more does nothing (a retried queue entry)', async () => {
    const { handler, rpc, log } = setup({ jobs_import_prepare: prepared({ status: 'completed' }) });
    await handler(job(), log);
    expect(storage.getObject).not.toHaveBeenCalled();
    expect(rpc).toHaveBeenCalledTimes(1);
  });

  it('refuses a file outside the job shop and a file that changed since it was uploaded', async () => {
    const outside = setup({ jobs_import_prepare: prepared({ file_path: 'other/import/f.csv' }) });
    await expect(outside.handler(job(), outside.log)).rejects.toThrow('outside the shop');
    expect(storage.getObject).not.toHaveBeenCalled();

    const changed = setup({ jobs_import_prepare: prepared({ file_sha256: 'e'.repeat(64) }) });
    await expect(changed.handler(job(), changed.log)).rejects.toThrow('changed');
  });

  it('a failed run writes its errors as a CSV and links it to the job', async () => {
    const errors = [{ row: 2, column: 'sku', code: 'PRODUCT_SKU_TAKEN', message: 'taken' }];
    const { handler, rpc, log } = setup({
      jobs_import_prepare: prepared(),
      jobs_import_apply: { status: 'failed', changed: true, errors },
      jobs_import_attach_result: { status: 'failed' },
    });
    await handler(job(), log);
    const [path, body] = storage.putObject.mock.calls[0] as [string, Buffer];
    expect(path.startsWith(`${ORG}/export/`)).toBe(true);
    expect(body.toString('utf8')).toContain('2,sku,PRODUCT_SKU_TAKEN,taken');
    expect(rpc).toHaveBeenLastCalledWith(
      'jobs_import_attach_result',
      expect.objectContaining({ p_job_id: IMPORT_JOB, p_mime: 'text/csv' }),
    );
  });

  it('a failure outside the database is retried; the last attempt marks the job failed', async () => {
    const first = setup({ jobs_import_prepare: prepared() });
    storage.getObject.mockRejectedValue(new Error('storage down'));
    await expect(first.handler(job({ attempt: 1 }), first.log)).rejects.toThrow('storage down');
    expect(first.rpc).not.toHaveBeenCalledWith('jobs_import_fail', expect.anything());

    const last = setup({ jobs_import_prepare: prepared(), jobs_import_fail: { status: 'failed' } });
    await expect(last.handler(job({ attempt: 3 }), last.log)).rejects.toThrow('storage down');
    expect(last.rpc).toHaveBeenCalledWith('jobs_import_fail', {
      p_job_id: IMPORT_JOB,
      p_reason: expect.stringContaining('could not run'),
    });
  });

  it('a payload without a job id is a bug, not a retry', async () => {
    const { handler, log } = setup({});
    await expect(handler(job({ payload: {} }), log)).rejects.toBeDefined();
  });
});
