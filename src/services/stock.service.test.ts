import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  cancelCount,
  createCount,
  getCount,
  listAdjustments,
  listStock,
  listStockMovements,
  postAdjustment,
  postCount,
  saveCountLines,
  scanCount,
} from './stock.service';

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

const adjustment = {
  id: ID,
  number: 'MAIN-SA-26-000001',
  branch_id: ID,
  reason: 'found',
  note: null,
  count_id: null,
  count_number: null,
  created_at: '2026-10-10T08:00:00+00:00',
  created_by_name: 'Owner',
  lines_count: 1,
  quantity_in: 2,
  quantity_out: 0,
};
const count = {
  id: ID,
  number: 'MAIN-SC-26-000001',
  branch_id: ID,
  category_id: null,
  category_name: null,
  status: 'open',
  created_at: '2026-10-10T08:00:00+00:00',
  created_by_name: 'Keeper',
  posted_at: null,
  posted_by_name: null,
  adjustment_id: null,
  adjustment_number: null,
  lines_total: 1,
  lines_counted: 1,
  lines_different: 1,
  quantity_in: 0,
  quantity_out: 1,
};
const countLine = {
  id: ID,
  product_id: ID,
  name_ar: 'كابل',
  name_en: null,
  sku: 'CB',
  barcode: null,
  is_serialized: false,
  unit_id: null,
  serial: null,
  expected_qty: 3,
  counted_qty: 2,
  difference: -1,
};

describe('I02 stock service', () => {
  it('posts an adjustment with nulls for the optional parts and the idempotency key', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { ...adjustment, lines: [] }, error: null });
    const res = await postAdjustment(
      ctx,
      { branch_id: ID, reason: 'found', lines: [{ product_id: ID, quantity: 2 }] },
      'key-12345678',
    );
    expect(res.number).toBe('MAIN-SA-26-000001');
    expect(db.rpc).toHaveBeenCalledWith('post_stock_adjustment', {
      p_branch_id: ID,
      p_reason: 'found',
      p_note: null,
      p_lines: [{ product_id: ID, unit_id: null, quantity: 2 }],
      p_idempotency_key: 'key-12345678',
    });
  });

  it('maps adjustment errors to contract codes', async () => {
    const { db, ctx } = setup();
    const body = {
      branch_id: ID,
      reason: 'loss' as const,
      lines: [{ product_id: ID, quantity: -9 }],
    };
    db.queue({ data: null, error: { message: 'OUT_OF_STOCK: product x at branch y' } });
    await expect(postAdjustment(ctx, body, 'key-12345678')).rejects.toMatchObject({
      code: 'OUT_OF_STOCK',
      statusCode: 409,
    });
    db.queue({
      data: null,
      error: { message: "ADJUSTMENT_SIGN_INVALID: loss can't move stock in" },
    });
    await expect(postAdjustment(ctx, body, 'key-12345678')).rejects.toMatchObject({
      code: 'ADJUSTMENT_SIGN_INVALID',
      statusCode: 400,
    });
    db.queue({ data: null, error: { message: 'something internal' } });
    await expect(postAdjustment(ctx, body, 'key-12345678')).rejects.toMatchObject({
      code: 'INTERNAL',
    });
  });

  it('lists adjustments with only the given filters', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [adjustment], total: 1 }, error: null });
    const list = await listAdjustments(ctx, { page: 1, pageSize: 20, reason: 'count' });
    expect(list.items[0]?.id).toBe(ID);
    expect(db.rpc).toHaveBeenCalledWith('list_stock_adjustments', {
      p_reason: 'count',
      p_limit: 20,
      p_offset: 0,
    });
  });

  it('creates a whole-branch count (category null) with the key', async () => {
    const { db, ctx } = setup();
    db.queue({ data: count, error: null });
    await createCount(ctx, { branch_id: ID }, 'key-12345678');
    expect(db.rpc).toHaveBeenCalledWith('create_stock_count', {
      p_branch_id: ID,
      p_category_id: null,
      p_idempotency_key: 'key-12345678',
    });
    db.queue({ data: null, error: { message: 'STOCK_COUNT_OPEN' } });
    await expect(createCount(ctx, { branch_id: ID }, 'key-12345678')).rejects.toMatchObject({
      code: 'STOCK_COUNT_OPEN',
      statusCode: 409,
    });
  });

  it('reads a count with a page of lines (paging added to the lines)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { ...count, lines: { items: [countLine], total: 41 } }, error: null });
    const detail = await getCount(ctx, ID, { page: 3, pageSize: 20, filter: 'different' });
    expect(detail.lines).toMatchObject({ page: 3, pageSize: 20, total: 41 });
    expect(detail.lines.items[0]).toEqual(countLine);
    expect(db.rpc).toHaveBeenCalledWith('get_stock_count', {
      p_id: ID,
      p_filter: 'different',
      p_limit: 20,
      p_offset: 40,
    });
  });

  it('saves lines, scans, posts and cancels', async () => {
    const { db, ctx } = setup();
    db.queue({ data: count, error: null });
    await saveCountLines(ctx, ID, { lines: [{ product_id: ID, counted_qty: null }] });
    expect(db.rpc).toHaveBeenCalledWith('save_stock_count_lines', {
      p_count_id: ID,
      p_lines: [{ product_id: ID, unit_id: null, counted_qty: null }],
    });
    db.queue({ data: countLine, error: null });
    expect(await scanCount(ctx, ID, 'CB')).toEqual(countLine);
    db.queue({ data: { ...count, status: 'posted' }, error: null });
    await postCount(ctx, ID, { uncounted_as_zero: true }, 'key-12345678');
    expect(db.rpc).toHaveBeenCalledWith('post_stock_count', {
      p_count_id: ID,
      p_uncounted_as_zero: true,
      p_idempotency_key: 'key-12345678',
    });
    db.queue({ data: null, error: { message: 'STOCK_COUNT_INCOMPLETE: 2 lines not counted' } });
    await expect(
      postCount(ctx, ID, { uncounted_as_zero: false }, 'key-12345678'),
    ).rejects.toMatchObject({ code: 'STOCK_COUNT_INCOMPLETE', statusCode: 409 });
    db.queue({ data: null, error: { message: 'DOCUMENT_FINAL: the count is posted' } });
    await expect(cancelCount(ctx, ID)).rejects.toMatchObject({ code: 'DOCUMENT_FINAL' });
  });
});
