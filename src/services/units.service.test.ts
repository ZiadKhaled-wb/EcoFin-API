import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { getUnit, registerUnits, searchUnits } from './units.service';

const ID = 'a0d00000-0000-4000-8000-000000000001';

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'OWNER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

const registration = {
  import_job_id: ID,
  kind: 'register_units',
  product_id: ID,
  branch_id: ID,
  cost: '7000.50',
  note: null,
  count: 1,
  units: [{ id: ID, serial: 'IMEI-1' }],
};

describe('I04 units service', () => {
  it('registers with a null note and the key', async () => {
    const { db, ctx } = setup();
    db.queue({ data: registration, error: null });
    const res = await registerUnits(
      ctx,
      { product_id: ID, branch_id: ID, cost: '7000.50', serials: ['IMEI-1'] },
      'key-12345678',
    );
    expect(res.units[0]?.serial).toBe('IMEI-1');
    expect(db.rpc).toHaveBeenCalledWith('register_units', {
      p_product_id: ID,
      p_branch_id: ID,
      p_cost: '7000.50',
      p_serials: ['IMEI-1'],
      p_note: null,
      p_idempotency_key: 'key-12345678',
    });
  });

  it('SERIAL_TAKEN carries the serials; other details are dropped', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: { message: 'SERIAL_TAKEN: 1 already in the shop', details: '{"serials":["IMEI-1"]}' },
    });
    await expect(
      registerUnits(
        ctx,
        { product_id: ID, branch_id: ID, cost: '1', serials: ['IMEI-1'] },
        'key-12345678',
      ),
    ).rejects.toMatchObject({
      code: 'SERIAL_TAKEN',
      statusCode: 409,
      details: { serials: ['IMEI-1'] },
    });
    db.queue({ data: null, error: { message: 'SERIAL_TAKEN', details: 'not json' } });
    await expect(
      registerUnits(
        ctx,
        { product_id: ID, branch_id: ID, cost: '1', serials: ['IMEI-1'] },
        'key-12345678',
      ),
    ).rejects.toMatchObject({ code: 'SERIAL_TAKEN', details: undefined });
  });

  it('finds by serial or id, and searches with only the given filters', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'UNIT_NOT_FOUND' } });
    await expect(getUnit(ctx, { serial: 'NOPE' })).rejects.toMatchObject({
      code: 'UNIT_NOT_FOUND',
      statusCode: 404,
    });
    expect(db.rpc).toHaveBeenLastCalledWith('find_unit', { p_serial: 'NOPE' });
    db.queue({ data: null, error: { message: 'BRANCH_DENIED' } });
    await expect(getUnit(ctx, { id: ID })).rejects.toMatchObject({ code: 'BRANCH_DENIED' });
    expect(db.rpc).toHaveBeenLastCalledWith('get_unit', { p_id: ID });
    db.queue({ data: { items: [], total: 0 }, error: null });
    await searchUnits(ctx, { page: 2, pageSize: 20, search: 'imei' });
    expect(db.rpc).toHaveBeenLastCalledWith('search_units', {
      p_search: 'imei',
      p_limit: 20,
      p_offset: 20,
    });
  });
});
