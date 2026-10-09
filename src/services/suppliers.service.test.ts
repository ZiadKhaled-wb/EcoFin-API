import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import {
  createSupplier,
  getSupplier,
  getSupplierStatement,
  listSuppliers,
  setSupplierArchived,
  updateSupplier,
} from './suppliers.service';

const ID = 'a0530000-0000-4000-8000-000000000001';
const row = (extra: Record<string, unknown> = {}) => ({
  id: ID,
  name: 'Nile Traders',
  phone: '01012345678',
  tax_registration_no: null,
  address: null,
  payment_terms_days: 30,
  notes: null,
  archived_at: null,
  created_at: '2026-10-11T08:00:00.000Z',
  updated_at: '2026-10-11T08:00:00.000Z',
  balance: '1050.25',
  ...extra,
});
const statement = {
  supplier: row(),
  from: '2026-09-10',
  to: null,
  opening_balance: '600.00',
  closing_balance: '1100.50',
  totals: { invoiced: '500.50', paid: '0.00', returned: '0.00' },
  rows: [
    {
      date: '2026-09-10',
      kind: 'invoice',
      document_id: 'a0530000-0000-4000-8000-000000000002',
      number: 'PI-2026-000002',
      reference: 'S-2',
      branch_id: 'a0530000-0000-4000-8000-000000000003',
      refund_mode: null,
      debit: '500.50',
      credit: '0.00',
      balance: '1100.50',
    },
  ],
};

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

describe('U01 supplier service', () => {
  it('lists with the paging turned into limit/offset and keeps the balance a string', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [row()], total: 51 }, error: null });
    const list = await listSuppliers(ctx, { page: 2, pageSize: 50, status: 'all', search: 'nile' });
    expect(list).toMatchObject({ page: 2, pageSize: 50, total: 51 });
    expect(list.items[0]!.balance).toBe('1050.25');
    expect(db.rpc).toHaveBeenCalledWith('list_suppliers', {
      p_search: 'nile',
      p_status: 'all',
      p_limit: 50,
      p_offset: 50,
    });
  });

  it('leaves the search out when not given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], total: 0 }, error: null });
    await listSuppliers(ctx, { page: 1, pageSize: 20, status: 'active' });
    expect(db.rpc).toHaveBeenCalledWith('list_suppliers', {
      p_status: 'active',
      p_limit: 20,
      p_offset: 0,
    });
  });

  it('gets a supplier and refuses a malformed row (balance as a number)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row(), error: null });
    expect(await getSupplier(ctx, ID)).toEqual(row());
    expect(db.rpc).toHaveBeenCalledWith('get_supplier', { p_id: ID });
    db.queue({ data: row({ balance: 1050.25 }), error: null });
    await expect(getSupplier(ctx, ID)).rejects.toThrow();
  });

  it('reads the statement with the dates given, and without them', async () => {
    const { db, ctx } = setup();
    db.queue({ data: statement, error: null });
    expect(await getSupplierStatement(ctx, ID, { from: '2026-09-10' })).toEqual(statement);
    expect(db.rpc).toHaveBeenCalledWith('supplier_statement', { p_id: ID, p_from: '2026-09-10' });
    db.queue({ data: { ...statement, from: null, opening_balance: '0.00' }, error: null });
    await getSupplierStatement(ctx, ID, {});
    expect(db.rpc).toHaveBeenLastCalledWith('supplier_statement', { p_id: ID });
    db.queue({ data: statement, error: null });
    await getSupplierStatement(ctx, ID, { from: '2026-09-01', to: '2026-09-30' });
    expect(db.rpc).toHaveBeenLastCalledWith('supplier_statement', {
      p_id: ID,
      p_from: '2026-09-01',
      p_to: '2026-09-30',
    });
  });

  it('creates, updates, archives and restores in one call each', async () => {
    const { db, ctx } = setup();
    const body = { name: 'Nile Traders', phone: '01012345678', payment_terms_days: 30 };
    db.queue({ data: row(), error: null });
    expect(await createSupplier(ctx, body)).toEqual(row());
    expect(db.rpc).toHaveBeenLastCalledWith('create_supplier', { p: body });
    db.queue({ data: row({ address: 'Giza' }), error: null });
    expect((await updateSupplier(ctx, ID, { address: 'Giza', phone: null })).address).toBe('Giza');
    expect(db.rpc).toHaveBeenLastCalledWith('update_supplier', {
      p_id: ID,
      p_changes: { address: 'Giza', phone: null },
    });
    db.queue({ data: row({ archived_at: '2026-10-11T09:00:00.000Z' }), error: null });
    expect((await setSupplierArchived(ctx, ID, true)).archived_at).not.toBeNull();
    expect(db.rpc).toHaveBeenLastCalledWith('set_supplier_archived', {
      p_id: ID,
      p_archived: true,
    });
    db.queue({ data: row(), error: null });
    await setSupplierArchived(ctx, ID, false);
    expect(db.rpc).toHaveBeenLastCalledWith('set_supplier_archived', {
      p_id: ID,
      p_archived: false,
    });
    expect(db.rpc).toHaveBeenCalledTimes(4);
  });

  it('throws the contract code when the database refuses, never the raw message', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'SUPPLIER_HAS_BALANCE: private detail' } });
    const err = await setSupplierArchived(ctx, ID, true).catch((e: unknown) => e);
    expect(err).toMatchObject({ code: 'SUPPLIER_HAS_BALANCE', statusCode: 409 });
    expect((err as Error).message).not.toContain('private detail');
  });

  it.each([
    ['SUPPLIER_NOT_FOUND', 404],
    ['SUPPLIER_NAME_TAKEN', 409],
    ['SUPPLIER_PHONE_TAKEN', 409],
    ['SUPPLIER_HAS_BALANCE', 409],
    ['SUPPLIER_HAS_OPEN_DOCUMENTS', 409],
  ] as const)('maps %s', (code, status) => {
    expect(mapDbError({ message: code + ': private detail' })).toMatchObject({
      code,
      statusCode: status,
    });
  });
});
