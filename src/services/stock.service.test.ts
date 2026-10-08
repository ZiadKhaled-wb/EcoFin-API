import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { listStock, listStockMovements } from './stock.service';

const ID = 'a0800000-0000-4000-8000-000000000001';
const row = {
  product_id: ID,
  name_ar: 'تلفزيون',
  name_en: null,
  sku: 'TV-55',
  barcode: null,
  category_id: null,
  is_serialized: false,
  archived_at: null,
  branch_id: ID,
  on_hand: 5,
  reserved: 2,
  available: 3,
  damaged: 0,
  in_transit: 1,
  min_level: 3,
  low: false,
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

describe('I01 stock service', () => {
  it('turns paging into limit/offset and passes only the given filters', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [row], total: 61 }, error: null });
    const list = await listStock(ctx, {
      page: 2,
      pageSize: 30,
      include_subcategories: true,
      low_only: true,
      branch_id: ID,
    });
    expect(list).toMatchObject({ page: 2, pageSize: 30, total: 61 });
    expect(list.items[0]).toEqual(row);
    expect(db.rpc).toHaveBeenCalledWith('list_stock', {
      p_branch_id: ID,
      p_include_children: true,
      p_low_only: true,
      p_limit: 30,
      p_offset: 30,
    });
  });

  it('refuses a malformed row (quantity as text)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [{ ...row, on_hand: '5' }], total: 1 }, error: null });
    await expect(
      listStock(ctx, { page: 1, pageSize: 50, include_subcategories: true, low_only: false }),
    ).rejects.toThrow();
  });

  it('maps branch and product errors to contract codes', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'BRANCH_DENIED: private' } });
    await expect(
      listStock(ctx, { page: 1, pageSize: 50, include_subcategories: true, low_only: false }),
    ).rejects.toMatchObject({ code: 'BRANCH_DENIED', statusCode: 403 });
    db.queue({ data: null, error: { message: 'PRODUCT_NOT_FOUND' } });
    await expect(
      listStockMovements(ctx, { product_id: ID, page: 1, pageSize: 50 }),
    ).rejects.toMatchObject({ code: 'PRODUCT_NOT_FOUND', statusCode: 404 });
  });

  it('lists movements for a product with optional branch', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], total: 0 }, error: null });
    await listStockMovements(ctx, { product_id: ID, page: 1, pageSize: 50 });
    expect(db.rpc).toHaveBeenCalledWith('list_stock_movements', {
      p_product_id: ID,
      p_limit: 50,
      p_offset: 0,
    });
  });
});
