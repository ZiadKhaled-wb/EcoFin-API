import { describe, it, expect, vi } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import { logger } from '../utils/logger';
import {
  createCustomer,
  getCustomer,
  listCustomers,
  setCustomerStatus,
  updateCustomer,
} from './customers.service';

const ID = 'a0630000-0000-4000-8000-000000000001';
const row = (extra: Record<string, unknown> = {}) => ({
  id: ID,
  full_name: 'Ahmed Ali Hassan',
  phones: ['01001234567'],
  national_id: null,
  national_id_masked: '**********0015',
  birth_date: '1990-01-01',
  gender: 'male',
  governorate_code: '01',
  address: null,
  city: null,
  job: null,
  employer: null,
  monthly_income: '8500.50',
  is_business: false,
  tax_registration_no: null,
  status: 'active',
  notes: null,
  id_photos_count: 0,
  collector: null,
  created_at: '2026-10-12T08:00:00.000Z',
  updated_at: '2026-10-12T08:00:00.000Z',
  ...extra,
});

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'CASHIER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('R01 customer service', () => {
  it('lists with the paging turned into limit/offset and passes the masked rows through', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [row()], total: 51 }, error: null });
    const list = await listCustomers(ctx, {
      page: 2,
      pageSize: 50,
      status: 'blocked',
      search: 'ahmed',
    });
    expect(list).toMatchObject({ page: 2, pageSize: 50, total: 51 });
    expect(list.items[0]).toMatchObject({
      national_id: null,
      national_id_masked: '**********0015',
    });
    expect(db.rpc).toHaveBeenCalledWith('list_customers', {
      p_search: 'ahmed',
      p_status: 'blocked',
      p_limit: 50,
      p_offset: 50,
    });
  });

  it('leaves the search out when not given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], total: 0 }, error: null });
    await listCustomers(ctx, { page: 1, pageSize: 20, status: 'all' });
    expect(db.rpc).toHaveBeenCalledWith('list_customers', {
      p_status: 'all',
      p_limit: 20,
      p_offset: 0,
    });
  });

  it('gets a customer and refuses a malformed row (income as a number)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row({ national_id: '29001010100015' }), error: null });
    expect((await getCustomer(ctx, ID)).national_id).toBe('29001010100015');
    expect(db.rpc).toHaveBeenCalledWith('get_customer', { p_id: ID });
    db.queue({ data: row({ monthly_income: 8500.5 }), error: null });
    await expect(getCustomer(ctx, ID)).rejects.toThrow();
  });

  it('creates and updates in one call each', async () => {
    const { db, ctx } = setup();
    const body = {
      full_name: 'Ahmed Ali Hassan',
      phones: ['01001234567'],
      national_id: '29001010100015',
      is_business: false,
    };
    db.queue({ data: row(), error: null });
    expect(await createCustomer(ctx, body)).toEqual(row());
    expect(db.rpc).toHaveBeenLastCalledWith('create_customer', { p: body });
    db.queue({ data: row({ city: 'Giza' }), error: null });
    expect((await updateCustomer(ctx, ID, { city: 'Giza', national_id: null })).city).toBe('Giza');
    expect(db.rpc).toHaveBeenLastCalledWith('update_customer', {
      p_id: ID,
      p_changes: { city: 'Giza', national_id: null },
    });
    expect(db.rpc).toHaveBeenCalledTimes(2);
  });

  it('blocks with the reason and unblocks without one', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row({ status: 'blocked' }), error: null });
    expect(
      (await setCustomerStatus(ctx, ID, { status: 'blocked', reason: 'bounced cheques' })).status,
    ).toBe('blocked');
    expect(db.rpc).toHaveBeenLastCalledWith('set_customer_status', {
      p_id: ID,
      p_status: 'blocked',
      p_reason: 'bounced cheques',
    });
    db.queue({ data: row(), error: null });
    await setCustomerStatus(ctx, ID, { status: 'active' });
    expect(db.rpc).toHaveBeenLastCalledWith('set_customer_status', {
      p_id: ID,
      p_status: 'active',
    });
  });

  it('a duplicate national ID carries who has it, never the raw message', async () => {
    const { db, ctx } = setup();
    const log = vi.spyOn(logger, 'error').mockImplementation(() => undefined);
    db.queue({
      data: null,
      error: {
        message: 'CUSTOMER_NATIONAL_ID_TAKEN',
        details: JSON.stringify({ customer_id: ID, full_name: 'Ahmed Ali Hassan' }),
      },
    });
    const err = await createCustomer(ctx, {
      full_name: 'Twin',
      phones: ['01000000002'],
      national_id: '29001010100015',
      is_business: false,
    }).catch((e: unknown) => e);
    expect(err).toMatchObject({
      code: 'CUSTOMER_NATIONAL_ID_TAKEN',
      statusCode: 409,
      details: { customer_id: ID, full_name: 'Ahmed Ali Hassan' },
    });
    expect(JSON.stringify(err)).not.toContain('29001010100015');
    // The server log gets the code, not the customer the detail names.
    expect(log).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(log.mock.calls)).not.toContain('Ahmed Ali Hassan');
    log.mockRestore();
  });

  it('drops a detail that is not the contract shape', () => {
    const err = mapDbError({
      message: 'CUSTOMER_NATIONAL_ID_TAKEN',
      details: JSON.stringify({ national_id: '29001010100015' }),
    });
    expect(err).toMatchObject({ code: 'CUSTOMER_NATIONAL_ID_TAKEN' });
    expect(err?.details).toBeUndefined();
  });

  it.each([
    ['CUSTOMER_NOT_FOUND', 404],
    ['CUSTOMER_NATIONAL_ID_TAKEN', 409],
    ['MODULE_NOT_IN_PLAN', 403],
    ['PERMISSION_DENIED', 403],
  ] as const)('maps %s', (code, status) => {
    expect(mapDbError({ message: code + ': private detail' })).toMatchObject({
      code,
      statusCode: status,
    });
  });
});
