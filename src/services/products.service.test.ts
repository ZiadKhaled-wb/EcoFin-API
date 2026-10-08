import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import {
  createProduct,
  getProduct,
  listProductUnits,
  listProducts,
  lookupProduct,
  setProductArchived,
  updateProduct,
} from './products.service';

const ID = 'a0400000-0000-4000-8000-000000000001';
const row = (id = ID, extra: Record<string, unknown> = {}) => ({
  id,
  name_ar: 'تلفزيون',
  name_en: null,
  sku: 'TV-55',
  barcode: '2000000000015',
  category_id: null,
  unit_of_measure: 'piece',
  cash_price: '15000.00',
  installment_price: null,
  avg_cost: '1234.5678',
  tax_class_id: 'a0400000-0000-4000-8000-000000000002',
  warranty_months: 0,
  is_serialized: false,
  min_stock: 0,
  image_file_id: null,
  eta_item_code: null,
  eta_item_type: null,
  archived_at: null,
  created_at: '2026-10-08T08:00:00.000Z',
  updated_at: '2026-10-08T08:00:00.000Z',
  ...extra,
});

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

describe('C02 product service', () => {
  it('lists with the paging turned into limit/offset and keeps decimal strings', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [row()], total: 51 }, error: null });
    const list = await listProducts(ctx, {
      page: 2,
      pageSize: 50,
      include_subcategories: false,
      status: 'all',
      search: 'tv',
      category_id: 'a0400000-0000-4000-8000-000000000003',
    });
    expect(list).toMatchObject({ page: 2, pageSize: 50, total: 51 });
    expect(list.items[0]).toMatchObject({ cash_price: '15000.00', avg_cost: '1234.5678' });
    expect(typeof list.items[0]!.cash_price).toBe('string');
    expect(db.rpc).toHaveBeenCalledWith('list_products', {
      p_search: 'tv',
      p_category_id: 'a0400000-0000-4000-8000-000000000003',
      p_include_children: false,
      p_status: 'all',
      p_limit: 50,
      p_offset: 50,
    });
  });

  it('leaves search and category out when not given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], total: 0 }, error: null });
    await listProducts(ctx, {
      page: 1,
      pageSize: 50,
      include_subcategories: true,
      status: 'active',
    });
    expect(db.rpc).toHaveBeenCalledWith('list_products', {
      p_include_children: true,
      p_status: 'active',
      p_limit: 50,
      p_offset: 0,
    });
  });

  it('refuses a malformed database row (money as a number)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row(ID, { cash_price: 15000 }), error: null });
    await expect(getProduct(ctx, ID)).rejects.toThrow();
  });

  it('looks up by code', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row(), error: null });
    expect(await lookupProduct(ctx, '2000000000015')).toMatchObject({ sku: 'TV-55' });
    expect(db.rpc).toHaveBeenCalledWith('lookup_product', { p_code: '2000000000015' });
  });

  it('creates, then reads the product back', async () => {
    const { db, ctx } = setup();
    db.queue({ data: ID, error: null });
    db.queue({ data: row(), error: null });
    const body = { name_ar: 'تلفزيون', sku: 'TV-55', cash_price: '15000.00' };
    expect(await createProduct(ctx, body)).toEqual(row());
    expect(db.rpc).toHaveBeenNthCalledWith(1, 'create_product', { p: body });
    expect(db.rpc).toHaveBeenNthCalledWith(2, 'get_product', { p_id: ID });
  });

  it('updates, archives and restores with the right rpc arguments', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: null });
    db.queue({ data: row(), error: null });
    await updateProduct(ctx, ID, { cash_price: '14000.00', barcode: null });
    expect(db.rpc).toHaveBeenCalledWith('update_product', {
      p_id: ID,
      p_changes: { cash_price: '14000.00', barcode: null },
    });
    db.queue({ data: null, error: null });
    db.queue({ data: row(ID, { archived_at: '2026-10-08T09:00:00.000Z' }), error: null });
    expect((await setProductArchived(ctx, ID, true)).archived_at).not.toBeNull();
    expect(db.rpc).toHaveBeenCalledWith('set_product_archived', { p_id: ID, p_archived: true });
    db.queue({ data: null, error: null });
    db.queue({ data: row(), error: null });
    await setProductArchived(ctx, ID, false);
    expect(db.rpc).toHaveBeenCalledWith('set_product_archived', { p_id: ID, p_archived: false });
  });

  it('throws the contract code when the database refuses', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'PRODUCT_SKU_TAKEN: private detail' } });
    await expect(
      createProduct(ctx, { name_ar: 'x', sku: 'TV-55', cash_price: '1.00' }),
    ).rejects.toMatchObject({ code: 'PRODUCT_SKU_TAKEN', statusCode: 409 });
  });

  it.each([
    ['PRODUCT_NOT_FOUND', 404],
    ['PRODUCT_SKU_TAKEN', 409],
    ['PRODUCT_BARCODE_TAKEN', 409],
    ['PRODUCT_SERIAL_LOCKED', 409],
    ['PRODUCT_CATEGORY_ARCHIVED', 409],
  ] as const)('maps %s', (code, status) => {
    expect(mapDbError({ message: code + ': private detail' })).toMatchObject({
      code,
      statusCode: status,
    });
  });

  it('lists units with the status filter and parses them', async () => {
    const { db, ctx } = setup();
    const unit = { id: ID, serial: 'IMEI-1', branch_id: ID, status: 'in_stock' };
    db.queue({ data: [unit], error: null });
    expect(await listProductUnits(ctx, ID, { status: 'in_stock' })).toEqual([unit]);
    expect(db.rpc).toHaveBeenCalledWith('list_product_units', {
      p_product_id: ID,
      p_status: 'in_stock',
    });
  });
});
