import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { sha256Hex } from './files.rules';
import type { FileTable } from './imports/parse';

const storage = vi.hoisted(() => ({
  getObject: vi.fn(),
  putObject: vi.fn(),
  removeObject: vi.fn(),
}));
vi.mock('./storage.service', () => storage);

import {
  cancelImport,
  createImport,
  getImport,
  inspectImport,
  listImports,
  resolveMapping,
  runImport,
} from './imports.service';

const ID = 'a0d00000-0000-4000-8000-000000000001';
const JOB = 'a0d00000-0000-4000-8000-0000000000b1';
const ORG = 'b0000000-0000-4000-8000-000000000001';
const KEY = 'import-key-0001';

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: ORG,
    role: 'OWNER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

const CSV = Buffer.from('Item Code,Product Name,Price,Brand\nA1,هاتف,9000,Samsung\nA2,كابل,50,\n');

const report = (over: Record<string, unknown> = {}) => ({
  columns: { mapping: { sku: 'Item Code' }, unmapped_headers: ['Brand'] },
  sheet: null,
  branch_id: null,
  warnings: [],
  errors: [],
  errors_total: 0,
  errors_truncated: false,
  actions: { create: 2, update: 0, unchanged: 0 },
  preview: [],
  will_create_categories: [],
  applied: null,
  failure: null,
  ...over,
});
const job = (over: Record<string, unknown> = {}, rep: Record<string, unknown> = {}) => ({
  id: JOB,
  kind: 'products',
  status: 'validated',
  file_id: ID,
  file_name: 'p.csv',
  result_file_id: null,
  branch_id: null,
  rows_total: 2,
  rows_ok: 2,
  rows_failed: 0,
  created_at: '2026-10-20T10:00:00.000000+00:00',
  finished_at: null,
  created_by: { id: ID, name: 'Owner' },
  report: report(rep),
  ...over,
});
const fileRow = (over: Record<string, unknown> = {}) => ({
  id: ID,
  purpose: 'import',
  path: `${ORG}/import/2026/10/${ID}.csv`,
  sha256: sha256Hex(CSV),
  ...over,
});

beforeEach(() => {
  storage.getObject.mockReset().mockResolvedValue(CSV);
  storage.putObject.mockReset().mockResolvedValue(undefined);
  storage.removeObject.mockReset().mockResolvedValue(true);
});

describe('M01 import service', () => {
  it('inspect: the headers, a sample and the automatic mapping; nothing is written', async () => {
    const { db, ctx } = setup();
    db.queue({ data: fileRow(), error: null });
    const res = await inspectImport(ctx, { kind: 'products', file_id: ID });
    expect(res.file_type).toBe('csv');
    expect(res.headers).toEqual(['Item Code', 'Product Name', 'Price', 'Brand']);
    expect(res.total_rows).toBe(2);
    expect(res.sample[0]).toEqual({
      'Item Code': 'A1',
      'Product Name': 'هاتف',
      Price: '9000',
      Brand: 'Samsung',
    });
    expect(res.suggestion).toEqual({
      mapping: { sku: 'Item Code', name_ar: 'Product Name', cash_price: 'Price' },
      unmapped_headers: ['Brand'],
      missing_required: [],
    });
    expect(db.rpc).not.toHaveBeenCalled();
  });

  it('another shop file, a file of another purpose and a file that changed are all refused', async () => {
    for (const row of [null, fileRow({ purpose: 'logo' })]) {
      const { db, ctx } = setup();
      db.queue({ data: row, error: null });
      await expect(inspectImport(ctx, { kind: 'products', file_id: ID })).rejects.toMatchObject({
        code: 'FILE_NOT_FOUND',
        statusCode: 404,
      });
    }
    const { db, ctx } = setup();
    db.queue({ data: fileRow({ sha256: 'f'.repeat(64) }), error: null });
    await expect(inspectImport(ctx, { kind: 'products', file_id: ID })).rejects.toMatchObject({
      code: 'IMPORT_FILE_UNREADABLE',
    });
  });

  it('a path outside the shop is never read from storage', async () => {
    const { db, ctx } = setup();
    db.queue({ data: fileRow({ path: 'other-shop/import/x.csv' }), error: null });
    await expect(inspectImport(ctx, { kind: 'products', file_id: ID })).rejects.toBeDefined();
    expect(storage.getObject).not.toHaveBeenCalled();
  });

  it('create: sends the rows by field key with the mapping used, never the file headers', async () => {
    const { db, ctx } = setup();
    db.queue({ data: fileRow(), error: null }, { data: job(), error: null });
    const res = await createImport(ctx, { kind: 'products', file_id: ID, idempotency_key: KEY });
    expect(res.status).toBe('validated');
    expect(db.rpc).toHaveBeenCalledWith('create_import', {
      p_kind: 'products',
      p_file_id: ID,
      p_branch_id: null,
      p_rows: [
        { row: 2, values: { sku: 'A1', name_ar: 'هاتف', cash_price: '9000' } },
        { row: 3, values: { sku: 'A2', name_ar: 'كابل', cash_price: '50' } },
      ],
      p_meta: {
        sheet: null,
        mapping: { sku: 'Item Code', name_ar: 'Product Name', cash_price: 'Price' },
        unmapped_headers: ['Brand'],
      },
      p_idempotency_key: KEY,
    });
    expect(storage.putObject).not.toHaveBeenCalled();
  });

  it('create: an explicit mapping overrides the automatic one; a bad or repeated header is refused', async () => {
    const { db, ctx } = setup();
    db.queue({ data: fileRow(), error: null }, { data: job(), error: null });
    await createImport(ctx, {
      kind: 'products',
      file_id: ID,
      idempotency_key: KEY,
      mapping: { sku: 'Brand', name_ar: 'Product Name', cash_price: 'Price' },
    });
    const args = db.rpc.mock.calls[0]?.[1] as { p_rows: { values: Record<string, string> }[] };
    expect(args.p_rows[0]?.values['sku']).toBe('Samsung');

    for (const mapping of [
      { sku: 'Nope', name_ar: 'Product Name', cash_price: 'Price' },
      { sku: 'Price', name_ar: 'Product Name', cash_price: 'Price' },
    ]) {
      const s = setup();
      s.db.queue({ data: fileRow(), error: null });
      await expect(
        createImport(s.ctx, { kind: 'products', file_id: ID, idempotency_key: KEY, mapping }),
      ).rejects.toMatchObject({ code: 'IMPORT_MAPPING_INVALID', statusCode: 422 });
    }
  });

  it('create: missing required columns -> IMPORT_MISSING_COLUMNS with the fields and the headers', async () => {
    const { db, ctx } = setup();
    const other = Buffer.from('Brand,Colour\nA,B\n');
    storage.getObject.mockResolvedValue(other);
    db.queue({ data: fileRow({ sha256: sha256Hex(other) }), error: null });
    const err = await createImport(ctx, {
      kind: 'products',
      file_id: ID,
      idempotency_key: KEY,
    }).catch((e: unknown) => e);
    expect(err).toMatchObject({
      code: 'IMPORT_MISSING_COLUMNS',
      statusCode: 422,
      details: {
        columns: ['cash_price', 'sku|barcode', 'name_ar|name_en'],
        headers: ['Brand', 'Colour'],
      },
    });
  });

  it('create: a file with no data rows is unreadable', async () => {
    const { db, ctx } = setup();
    const only = Buffer.from('sku,name_ar,cash_price\n');
    storage.getObject.mockResolvedValue(only);
    db.queue({ data: fileRow({ sha256: sha256Hex(only) }), error: null });
    await expect(
      createImport(ctx, { kind: 'products', file_id: ID, idempotency_key: KEY }),
    ).rejects.toMatchObject({ code: 'IMPORT_FILE_UNREADABLE' });
  });

  it('create: a failed dry run gets its errors written as a CSV and linked to the job', async () => {
    const { db, ctx } = setup();
    const errors = [
      { row: 3, column: 'name_ar', code: 'IMPORT_REQUIRED', message: 'a name is required' },
    ];
    const failed = job(
      { status: 'failed', rows_ok: 1, rows_failed: 1 },
      { errors, errors_total: 1 },
    );
    db.queue(
      { data: fileRow(), error: null },
      { data: failed, error: null },
      { data: { ...failed, result_file_id: ID }, error: null },
    );
    const res = await createImport(ctx, { kind: 'products', file_id: ID, idempotency_key: KEY });
    expect(res.result_file_id).toBe(ID);
    expect(storage.putObject).toHaveBeenCalledTimes(1);
    const [path, body, mime] = storage.putObject.mock.calls[0] as [string, Buffer, string];
    expect(path.startsWith(`${ORG}/export/`)).toBe(true);
    expect(path.endsWith('.csv')).toBe(true);
    expect(mime).toBe('text/csv');
    expect(body.toString('utf8')).toContain('3,name_ar,IMPORT_REQUIRED,a name is required');
    expect(db.rpc).toHaveBeenLastCalledWith(
      'attach_import_result',
      expect.objectContaining({ p_job_id: JOB, p_mime: 'text/csv', p_size_bytes: body.length }),
    );
  });

  it('create: if linking the errors file fails, the object is removed and the job is still returned', async () => {
    const { db, ctx } = setup();
    const errors = [{ row: 3, column: null, code: 'IMPORT_REQUIRED', message: 'x' }];
    db.queue(
      { data: fileRow(), error: null },
      { data: job({ status: 'failed' }, { errors, errors_total: 1 }), error: null },
      { data: null, error: { message: 'boom' } },
    );
    const res = await createImport(ctx, { kind: 'products', file_id: ID, idempotency_key: KEY });
    expect(res.status).toBe('failed');
    expect(storage.removeObject).toHaveBeenCalledTimes(1);
  });

  it('a database error that is a contract code becomes that code', async () => {
    const { db, ctx } = setup();
    db.queue(
      { data: fileRow(), error: null },
      { data: null, error: { message: 'BRANCH_NOT_FOUND' } },
    );
    await expect(
      createImport(ctx, {
        kind: 'opening_stock',
        file_id: ID,
        branch_id: ID,
        idempotency_key: KEY,
        mapping: { sku: 'Item Code', quantity: 'Price', unit_cost: 'Product Name' },
      }),
    ).rejects.toMatchObject({ code: 'BRANCH_NOT_FOUND' });
  });

  it('list, get, run and cancel call their SQL functions and check the answer', async () => {
    const { db, ctx } = setup();
    db.queue(
      { data: { items: [], next_cursor: null }, error: null },
      { data: job(), error: null },
      { data: job({ status: 'importing' }), error: null },
      { data: job({ status: 'cancelled' }), error: null },
    );
    expect(await listImports(ctx, { kind: 'products', limit: 10 })).toEqual({
      items: [],
      next_cursor: null,
    });
    expect(db.rpc).toHaveBeenLastCalledWith('list_import_jobs', {
      p_filters: { kind: 'products', limit: 10 },
    });
    expect((await getImport(ctx, JOB)).id).toBe(JOB);
    expect((await runImport(ctx, JOB, { idempotency_key: KEY })).status).toBe('importing');
    expect(db.rpc).toHaveBeenLastCalledWith('queue_import', { p_id: JOB, p_idempotency_key: KEY });
    expect((await cancelImport(ctx, JOB)).status).toBe('cancelled');
  });

  it('IMPORT_NOT_VALIDATED carries the status of the job', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: { message: 'IMPORT_NOT_VALIDATED: the job is failed', details: '{"status":"failed"}' },
    });
    await expect(runImport(ctx, JOB, { idempotency_key: KEY })).rejects.toMatchObject({
      code: 'IMPORT_NOT_VALIDATED',
      statusCode: 409,
      details: { status: 'failed' },
    });
  });
});

describe('M01 resolveMapping', () => {
  const table: FileTable = {
    fileType: 'csv',
    sheets: [],
    sheet: null,
    headers: ['A', 'B'],
    rows: [],
  };
  it('uses the automatic mapping when none is given', () => {
    expect(
      resolveMapping('suppliers', { ...table, headers: ['Supplier Name'] }, undefined),
    ).toEqual({ name: 'Supplier Name' });
  });
});
