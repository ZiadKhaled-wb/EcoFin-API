import { describe, it, expect, vi } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import { logger } from '../utils/logger';
import {
  createGuarantor,
  getGuarantor,
  getGuarantorRequirement,
  linkCustomerGuarantor,
  listCustomerGuarantors,
  listGuarantors,
  setCustomerGuarantorRelation,
  setGuarantorArchived,
  unlinkCustomerGuarantor,
  updateGuarantor,
} from './guarantors.service';

const ID = 'a0710000-0000-4000-8000-000000000001';
const CUSTOMER = 'a0710000-0000-4000-8000-000000000002';
const row = (extra: Record<string, unknown> = {}) => ({
  id: ID,
  full_name: 'Mahmoud Hassan',
  phone: '01001234567',
  national_id: null,
  national_id_masked: '**********0015',
  birth_date: null,
  gender: null,
  address: null,
  job: 'Teacher',
  monthly_income: '6000.00',
  also_customer: null,
  archived_at: null,
  id_photos_count: 0,
  created_at: '2026-10-15T08:00:00.000Z',
  updated_at: '2026-10-15T08:00:00.000Z',
  ...extra,
});
const linked = (extra: Record<string, unknown> = {}) =>
  row({
    relation: 'father',
    linked_at: '2026-10-15T08:00:00.000Z',
    on_active_contract: false,
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

describe('R04 guarantor service', () => {
  it('lists with the paging turned into limit/offset and passes the masked rows through', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [row()], total: 51 }, error: null });
    const list = await listGuarantors(ctx, {
      page: 2,
      pageSize: 50,
      status: 'archived',
      search: 'mahmoud',
    });
    expect(list).toMatchObject({ page: 2, pageSize: 50, total: 51 });
    expect(list.items[0]).toMatchObject({
      national_id: null,
      national_id_masked: '**********0015',
    });
    expect(db.rpc).toHaveBeenCalledWith('list_guarantors', {
      p_search: 'mahmoud',
      p_status: 'archived',
      p_limit: 50,
      p_offset: 50,
    });
  });

  it('leaves the search out when not given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], total: 0 }, error: null });
    await listGuarantors(ctx, { page: 1, pageSize: 20, status: 'active' });
    expect(db.rpc).toHaveBeenCalledWith('list_guarantors', {
      p_status: 'active',
      p_limit: 20,
      p_offset: 0,
    });
  });

  it('gets the details and refuses a malformed row (income as a number)', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: {
        ...row({ national_id: '29001010100015' }),
        customers: [
          {
            customer_id: CUSTOMER,
            full_name: 'Ahmed',
            relation: 'friend',
            linked_at: '2026-10-15T08:00:00.000Z',
          },
        ],
        contracts: [],
      },
      error: null,
    });
    const details = await getGuarantor(ctx, ID);
    expect(details.national_id).toBe('29001010100015');
    expect(details.customers[0]?.relation).toBe('friend');
    expect(db.rpc).toHaveBeenCalledWith('get_guarantor', { p_id: ID });
    db.queue({
      data: { ...row({ monthly_income: 6000 }), customers: [], contracts: [] },
      error: null,
    });
    await expect(getGuarantor(ctx, ID)).rejects.toThrow();
  });

  it('creates (with a link) and updates in one call each', async () => {
    const { db, ctx } = setup();
    const body = {
      full_name: 'Mahmoud Hassan',
      phone: '01001234567',
      national_id: '29001010100015',
      link: { customer_id: CUSTOMER, relation: 'father' as const },
    };
    db.queue({ data: row(), error: null });
    expect(await createGuarantor(ctx, body)).toEqual(row());
    expect(db.rpc).toHaveBeenLastCalledWith('create_guarantor', { p_body: body });
    db.queue({ data: row({ job: 'Driver' }), error: null });
    expect((await updateGuarantor(ctx, ID, { job: 'Driver', address: null })).job).toBe('Driver');
    expect(db.rpc).toHaveBeenLastCalledWith('update_guarantor', {
      p_id: ID,
      p_body: { job: 'Driver', address: null },
    });
    expect(db.rpc).toHaveBeenCalledTimes(2);
  });

  it('archives and restores with the same function', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row({ archived_at: '2026-10-15T09:00:00.000Z' }), error: null });
    expect((await setGuarantorArchived(ctx, ID, true)).archived_at).not.toBeNull();
    expect(db.rpc).toHaveBeenLastCalledWith('set_guarantor_archived', {
      p_id: ID,
      p_archived: true,
    });
    db.queue({ data: row(), error: null });
    expect((await setGuarantorArchived(ctx, ID, false)).archived_at).toBeNull();
    expect(db.rpc).toHaveBeenLastCalledWith('set_guarantor_archived', {
      p_id: ID,
      p_archived: false,
    });
  });

  it("reads, links, relates and unlinks a customer's guarantors, always answering the list", async () => {
    const { db, ctx } = setup();
    db.queue({ data: [linked()], error: null });
    expect(await listCustomerGuarantors(ctx, CUSTOMER)).toHaveLength(1);
    expect(db.rpc).toHaveBeenLastCalledWith('list_customer_guarantors', {
      p_customer_id: CUSTOMER,
    });
    db.queue({ data: [linked(), linked({ id: CUSTOMER })], error: null });
    expect(
      await linkCustomerGuarantor(ctx, CUSTOMER, { guarantor_id: ID, relation: 'brother' }),
    ).toHaveLength(2);
    expect(db.rpc).toHaveBeenLastCalledWith('link_customer_guarantor', {
      p_customer_id: CUSTOMER,
      p_guarantor_id: ID,
      p_relation: 'brother',
    });
    db.queue({ data: [linked({ relation: 'colleague' })], error: null });
    expect(
      (await setCustomerGuarantorRelation(ctx, CUSTOMER, ID, { relation: 'colleague' }))[0]
        ?.relation,
    ).toBe('colleague');
    expect(db.rpc).toHaveBeenLastCalledWith('set_customer_guarantor_relation', {
      p_customer_id: CUSTOMER,
      p_guarantor_id: ID,
      p_relation: 'colleague',
    });
    db.queue({ data: [], error: null });
    expect(await unlinkCustomerGuarantor(ctx, CUSTOMER, ID)).toEqual([]);
    expect(db.rpc).toHaveBeenLastCalledWith('unlink_customer_guarantor', {
      p_customer_id: CUSTOMER,
      p_guarantor_id: ID,
    });
  });

  it('asks for the requirement with the financed amount as text', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: {
        policy_id: ID,
        policy_version: 2,
        required_above: '10000.00',
        required_count: 2,
        linked_active_count: 1,
        met: false,
      },
      error: null,
    });
    expect(
      await getGuarantorRequirement(ctx, CUSTOMER, { financed_amount: '15000.00' }),
    ).toMatchObject({ required_count: 2, met: false });
    expect(db.rpc).toHaveBeenCalledWith('get_guarantor_requirement', {
      p_customer_id: CUSTOMER,
      p_financed_amount: '15000.00',
    });
  });

  it('a duplicate national ID carries who has it, never the raw message', async () => {
    const { db, ctx } = setup();
    const log = vi.spyOn(logger, 'error').mockImplementation(() => undefined);
    db.queue({
      data: null,
      error: {
        message: 'GUARANTOR_NATIONAL_ID_TAKEN',
        details: JSON.stringify({ guarantor_id: ID, full_name: 'Mahmoud Hassan' }),
      },
    });
    const err = await createGuarantor(ctx, {
      full_name: 'Twin',
      phone: '01000000002',
      national_id: '29001010100015',
    }).catch((e: unknown) => e);
    expect(err).toMatchObject({
      code: 'GUARANTOR_NATIONAL_ID_TAKEN',
      statusCode: 409,
      details: { guarantor_id: ID, full_name: 'Mahmoud Hassan' },
    });
    expect(JSON.stringify(err)).not.toContain('29001010100015');
    // The server log gets the code, not the guarantor the detail names.
    expect(log).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(log.mock.calls)).not.toContain('Mahmoud Hassan');
    log.mockRestore();
  });

  it('GUARANTOR_REQUIRED says how many were needed and given', () => {
    const err = mapDbError({
      message: 'GUARANTOR_REQUIRED',
      details: JSON.stringify({ required: 2, given: 1 }),
    });
    expect(err).toMatchObject({
      code: 'GUARANTOR_REQUIRED',
      statusCode: 409,
      details: { required: 2, given: 1 },
    });
  });

  it('drops a detail that is not the contract shape', () => {
    const err = mapDbError({
      message: 'GUARANTOR_NATIONAL_ID_TAKEN',
      details: JSON.stringify({ national_id: '29001010100015' }),
    });
    expect(err).toMatchObject({ code: 'GUARANTOR_NATIONAL_ID_TAKEN' });
    expect(err?.details).toBeUndefined();
  });

  it.each([
    ['GUARANTOR_NOT_FOUND', 404],
    ['GUARANTOR_NATIONAL_ID_TAKEN', 409],
    ['GUARANTOR_ALREADY_LINKED', 409],
    ['GUARANTOR_NOT_LINKED', 409],
    ['GUARANTOR_LIMIT_REACHED', 409],
    ['GUARANTOR_IS_CUSTOMER', 409],
    ['GUARANTOR_ARCHIVED', 409],
    ['GUARANTOR_ON_ACTIVE_CONTRACT', 409],
    ['GUARANTOR_REQUIRED', 409],
    ['CUSTOMER_BLOCKED', 409],
    ['PERMISSION_DENIED', 403],
  ] as const)('maps %s', (code, status) => {
    expect(mapDbError({ message: code + ': private detail' })).toMatchObject({
      code,
      statusCode: status,
    });
  });
});
