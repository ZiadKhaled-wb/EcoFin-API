import { readFileSync } from 'node:fs';
import type { SupabaseClient } from '@supabase/supabase-js';
import pino from 'pino';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ExportManifest } from '@ziadkhaled-wb/contracts';
import { parseCsv, readZip } from '../../../scripts/export-restore-check.mjs';
import type { Job } from '../types';

const storage = vi.hoisted(() => ({ putObjectFile: vi.fn(), removeObject: vi.fn() }));
vi.mock('../../services/storage.service', () => storage);

import { exportFull, exportZipName, type ExportSnapshot } from './exportFull';
import { jobHandlers } from '../registry';

const ORG = '22222222-2222-4222-8222-222222222222';
const JOB = '33333333-3333-4333-8333-333333333333';
const EMP = '44444444-4444-4444-8444-444444444444';

const TOTALS = {
  cash_balance_total: '10.50',
  stock_on_hand_total: '3',
  store_credit_total: '0.00',
  open_contracts_remaining: '0.00',
  sales_total: '0.00',
  payments_in_total: '0.00',
  payments_out_total: '0.00',
  audit_rows: 0,
};

const job = (over: Partial<Job> = {}): Job => ({
  id: '11111111-1111-4111-8111-111111111111',
  organizationId: ORG,
  type: 'export.full',
  payload: { export_job_id: JOB },
  attempt: 1,
  maxAttempts: 2,
  ...over,
});

const prepared = (over: Record<string, unknown> = {}) => ({
  status: 'importing',
  changed: true,
  organization_id: ORG,
  pii: 'masked',
  requested_by: { id: EMP, name: 'Owner' },
  shop: { id: ORG, name: 'Dev Shop', tenant_slug: 'dev-shop' },
  migration: '20261027090000_m03_full_export',
  tables: ['customers', 'products'],
  columns: { customers: ['id', 'full_name', 'phones'], products: ['id', 'name_ar'] },
  keys: { customers: ['id'], products: ['id'] },
  json_columns: { customers: ['phones'], products: [] },
  ...over,
});

const ROWS: Record<string, { id: string; cells: (string | null)[] }[]> = {
  customers: [
    { id: 'a', cells: ['a', '=1+1', '["010", "011"]'] },
    { id: 'b', cells: ['b', 'علي, محمد', null] },
    { id: 'c', cells: ['c', 'plain', '[]'] },
  ],
  products: [],
};

/** A snapshot that serves ROWS in keyset pages and records the SQL it was asked. */
function fakeSnapshot(counts: Record<string, number>, calls: unknown[][] = []): ExportSnapshot {
  return {
    query: async (text, values = []) => {
      calls.push([text, ...values]);
      if (text.includes('jobs_export_counts')) return [{ v: counts }];
      if (text.includes('jobs_export_totals')) return [{ v: TOTALS }];
      const [, table, after, limit] = values as [string, string, string[] | null, number];
      const all = ROWS[table] ?? [];
      const start = after ? all.findIndex((r) => r.id === after[0]) + 1 : 0;
      return all.slice(start, start + limit).map((r) => ({
        row_json: JSON.stringify({ id: r.id, full_name: r.cells[1] }),
        cells: r.cells,
        key_vals: [r.id],
      }));
    },
    close: vi.fn(async () => undefined),
  };
}

interface Answer {
  data: unknown;
  error: { message: string } | null;
}

function setup(opts: {
  answers?: Record<string, unknown>;
  counts?: Record<string, number>;
  state?: () => string;
  limits?: { maxBytes: number; maxRows: number };
  snapshot?: ExportSnapshot | null;
  calls?: unknown[][];
}) {
  const answers: Record<string, unknown> = {
    jobs_export_prepare: prepared(),
    jobs_export_complete: { status: 'completed', changed: true },
    jobs_export_fail: { status: 'failed', changed: true },
    ...opts.answers,
  };
  const rpc = vi.fn(async (fn: string, _args?: Record<string, unknown>): Promise<Answer> => {
    if (fn === 'jobs_export_state') {
      return { data: opts.state ? opts.state() : 'importing', error: null };
    }
    return { data: answers[fn] ?? null, error: null };
  });
  const snapshot =
    opts.snapshot === undefined
      ? fakeSnapshot(opts.counts ?? { customers: 3, products: 0 }, opts.calls)
      : opts.snapshot;
  const handler = exportFull({
    db: { rpc } as unknown as SupabaseClient,
    openSnapshot: snapshot === null ? null : async () => snapshot,
    pageRows: 2,
    ...(opts.limits ? { limits: opts.limits } : {}),
  });
  return { rpc, handler, snapshot, log: pino({ level: 'silent' }) };
}

let uploaded: Buffer | null = null;
beforeEach(() => {
  uploaded = null;
  storage.putObjectFile.mockReset().mockImplementation(async (_path: string, file: string) => {
    uploaded = readFileSync(file);
  });
  storage.removeObject.mockReset().mockResolvedValue(true);
});

const failCall = (rpc: { mock: { calls: unknown[][] } }): Record<string, unknown> =>
  (rpc.mock.calls.find((c) => c[0] === 'jobs_export_fail')?.[1] as Record<string, unknown>) ?? {};

describe('export.full job (M03)', () => {
  it('is registered, and the daily cleanup too', () => {
    const handlers = jobHandlers({} as SupabaseClient, pino({ level: 'silent' }));
    expect(typeof handlers['export.full']).toBe('function');
    expect(typeof handlers['export.cleanup']).toBe('function');
  });

  it('builds the zip: CSV with BOM and formula guard, JSON, manifest equal to the snapshot', async () => {
    const calls: unknown[][] = [];
    const { handler, rpc, log, snapshot } = setup({ calls });
    await handler(job(), log);

    const entries = readZip(uploaded as unknown as Buffer);
    expect(Object.keys(entries).sort()).toEqual([
      'README.txt',
      'csv/customers.csv',
      'csv/products.csv',
      'json/customers.json',
      'json/products.json',
      'manifest.json',
    ]);
    const csv = (entries['csv/customers.csv'] as Buffer).toString('utf8');
    expect(csv.charCodeAt(0)).toBe(0xfeff);
    const rows = parseCsv(csv);
    expect(rows[0]).toEqual(['id', 'full_name', 'phones']);
    expect(rows).toHaveLength(4);
    expect(rows[1]?.[1]).toBe("'=1+1"); // the formula guard
    expect(rows[2]?.[1]).toBe('علي, محمد'); // Arabic and a comma survive
    expect(rows[1]?.[2]).toBe('["010","011"]'); // jsonb and array cells are compact
    expect(rows[2]?.[2]).toBe(''); // NULL is an empty cell
    expect(parseCsv((entries['csv/products.csv'] as Buffer).toString('utf8'))).toEqual([
      ['id', 'name_ar'],
    ]);

    expect(JSON.parse((entries['json/customers.json'] as Buffer).toString())).toHaveLength(3);
    expect(JSON.parse((entries['json/products.json'] as Buffer).toString())).toEqual([]);

    const manifest = ExportManifest.parse(
      JSON.parse((entries['manifest.json'] as Buffer).toString()),
    );
    expect(manifest.tables).toEqual([
      { name: 'customers', rows: 3, columns: ['id', 'full_name', 'phones'] },
      { name: 'products', rows: 0, columns: ['id', 'name_ar'] },
    ]);
    expect(manifest.totals).toEqual(TOTALS);
    expect(manifest.pii).toBe('masked');
    expect(manifest.shop.tenant_slug).toBe('dev-shop');

    // Pages of 2 rows: the second customers page starts after the first page's last key.
    const pages = calls.filter(
      (c) => String(c[0]).includes('jobs_export_page') && c[2] === 'customers',
    );
    expect(pages.map((c) => c[3])).toEqual([null, ['b']]);
    expect(snapshot?.close).toHaveBeenCalled();
    const complete = rpc.mock.calls.find((c) => c[0] === 'jobs_export_complete')?.[1] ?? {};
    expect(complete['p_rows']).toBe(3);
    expect(String(complete['p_path'])).toMatch(
      new RegExp(`^${ORG}/export/\\d{4}/\\d{2}/[0-9a-f-]{36}\\.zip$`),
    );
    expect(complete['p_original_name']).toMatch(/^ecofin-export-dev-shop-\d{8}-\d{4}\.zip$/);
    expect(storage.removeObject).not.toHaveBeenCalled();
  });

  it('does nothing for a job that is not importing any more (a retried queue entry)', async () => {
    const { handler, rpc, log } = setup({
      answers: { jobs_export_prepare: { status: 'completed', changed: false } },
    });
    await handler(job(), log);
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(storage.putObjectFile).not.toHaveBeenCalled();
  });

  it('stops at the next page when the export was cancelled, and uploads nothing', async () => {
    const { handler, rpc, log } = setup({ state: () => 'cancelled' });
    await handler(job(), log);
    expect(storage.putObjectFile).not.toHaveBeenCalled();
    expect(
      rpc.mock.calls.some((c) => c[0] === 'jobs_export_complete' || c[0] === 'jobs_export_fail'),
    ).toBe(false);
  });

  it('removes the object when the job was cancelled while the zip was built', async () => {
    const { handler, log } = setup({
      answers: { jobs_export_complete: { status: 'cancelled', changed: false } },
    });
    await handler(job(), log);
    expect(storage.removeObject).toHaveBeenCalledTimes(1);
  });

  it('fails with the numbers, without a retry, when the shop has too many rows', async () => {
    const { handler, rpc, log } = setup({ limits: { maxBytes: 1_000_000, maxRows: 2 } });
    await handler(job(), log);
    expect(failCall(rpc)['p_code']).toBe('EXPORT_TOO_LARGE');
    expect(failCall(rpc)['p_detail']).toMatchObject({ total_rows: 3, limit_rows: 2 });
    expect(storage.putObjectFile).not.toHaveBeenCalled();
  });

  it('fails when the files grow past the size limit', async () => {
    const { handler, rpc, log } = setup({ limits: { maxBytes: 50, maxRows: 100 } });
    await handler(job(), log);
    expect(failCall(rpc)['p_code']).toBe('EXPORT_TOO_LARGE');
    expect(failCall(rpc)['p_detail']).toMatchObject({ limit_bytes: 50 });
  });

  it('fails clearly, without a retry, when no direct database connection is configured', async () => {
    const { handler, rpc, log } = setup({ snapshot: null });
    await handler(job(), log);
    expect(failCall(rpc)['p_code']).toBe('EXPORT_FAILED');
  });

  it('a count that differs from the snapshot is an error: retried, and the last attempt marks it failed', async () => {
    const wrong = { counts: { customers: 5, products: 0 } };
    const first = setup(wrong);
    await expect(first.handler(job({ attempt: 1 }), first.log)).rejects.toThrow(/counted 5/);
    expect(first.rpc.mock.calls.some((c) => c[0] === 'jobs_export_fail')).toBe(false);
    const last = setup(wrong);
    await expect(last.handler(job({ attempt: 2 }), last.log)).rejects.toThrow(/counted 5/);
    expect(failCall(last.rpc)['p_code']).toBe('EXPORT_FAILED');
    expect(storage.putObjectFile).not.toHaveBeenCalled();
  });

  it('removes the uploaded object when it could not be registered', async () => {
    const { handler, rpc, log } = setup({});
    rpc.mockImplementation(async (fn: string): Promise<Answer> => {
      if (fn === 'jobs_export_prepare') return { data: prepared(), error: null };
      if (fn === 'jobs_export_state') return { data: 'importing', error: null };
      if (fn === 'jobs_export_complete') return { data: null, error: { message: 'boom' } };
      return { data: null, error: null };
    });
    await expect(handler(job({ attempt: 1 }), log)).rejects.toThrow(/jobs_export_complete failed/);
    expect(storage.removeObject).toHaveBeenCalledTimes(1);
  });

  it('names the zip after the shop and the minute', () => {
    expect(exportZipName('dev shop/1', new Date('2026-10-21T08:05:30Z'))).toBe(
      'ecofin-export-dev-shop-1-20261021-0805.zip',
    );
  });
});
