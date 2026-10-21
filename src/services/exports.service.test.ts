import { describe, expect, it } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { AppError } from '../utils/errors';
import { cancelExport, getExport, listExports, startExport } from './exports.service';

const ID = 'a0f00000-0000-4000-8000-000000000001';
const ID2 = 'a0f00000-0000-4000-8000-000000000002';
const ts = '2026-10-22T10:00:00.000Z';
const job = {
  id: ID,
  status: 'queued',
  requested_by: { id: ID2, name: 'Owner' },
  requested_at: ts,
  finished_at: null,
  pii: 'masked',
  rows: 0,
  size_bytes: null,
  file_id: null,
  file_name: null,
  file_removed_at: null,
  error_code: null,
};

function setup() {
  const db = createSupabaseMock();
  const ctx = {
    userId: 'u1',
    employeeId: ID2,
    orgId: ID,
    role: 'OWNER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  } as RequestContext;
  return { db, ctx };
}

const errorOf = async (p: Promise<unknown>) => {
  try {
    await p;
  } catch (e) {
    return e as AppError;
  }
  throw new Error('did not throw');
};

describe('exports service (M03)', () => {
  it('starts an export with the body and the idempotency key, and parses the answer', async () => {
    const { db, ctx } = setup();
    db.queue({ data: job, error: null });
    const out = await startExport(ctx, { pii: 'masked' }, 'key-12345678');
    expect(out.status).toBe('queued');
    expect(db.rpc).toHaveBeenCalledWith('start_full_export', {
      p_body: { pii: 'masked' },
      p_idempotency_key: 'key-12345678',
    });
  });

  it('lists, reads and cancels through the database functions', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [job] }, error: null });
    expect((await listExports(ctx)).items).toHaveLength(1);
    db.queue({ data: job, error: null });
    expect((await getExport(ctx, ID)).id).toBe(ID);
    db.queue({ data: { ...job, status: 'cancelled' }, error: null });
    expect((await cancelExport(ctx, ID)).status).toBe('cancelled');
    expect(db.rpc).toHaveBeenNthCalledWith(2, 'get_export', { p_id: ID });
    expect(db.rpc).toHaveBeenNthCalledWith(3, 'cancel_export', { p_id: ID });
  });

  it('maps the export errors, with their details, and hides raw database messages', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: { message: 'EXPORT_RUNNING', details: JSON.stringify({ job_id: ID }) },
    });
    const running = await errorOf(startExport(ctx, { pii: 'masked' }, 'key-12345678'));
    expect(running.code).toBe('EXPORT_RUNNING');
    expect(running.statusCode).toBe(409);
    expect(running.details).toEqual({ job_id: ID });

    db.queue({
      data: null,
      error: { message: 'EXPORT_TOO_SOON', details: JSON.stringify({ retry_after: 90 }) },
    });
    const soon = await errorOf(startExport(ctx, { pii: 'masked' }, 'key-12345678'));
    expect(soon.statusCode).toBe(429);
    expect(soon.details).toEqual({ retry_after: 90 });

    db.queue({ data: null, error: { message: 'EXPORT_NOT_FOUND' } });
    expect((await errorOf(getExport(ctx, ID))).statusCode).toBe(404);

    db.queue({ data: null, error: { message: 'relation "secret_table" does not exist' } });
    const raw = await errorOf(listExports(ctx));
    expect(raw.statusCode).toBe(500);
    expect(raw.message).not.toContain('secret_table');
  });
});
