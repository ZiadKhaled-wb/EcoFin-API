import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import {
  createCategory,
  listCategories,
  setCategoryArchived,
  updateCategory,
} from './categories.service';

const row = (id: string, name: string, parentId: string | null = null) => ({
  id,
  name,
  parent_id: parentId,
  archived_at: null,
  active_product_count: 0,
  created_at: '2026-10-07T08:00:00.000Z',
  updated_at: '2026-10-07T08:00:00.000Z',
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

describe('C01 category service', () => {
  it('lists the caller shop categories parsed with the contract', async () => {
    const { db, ctx } = setup();
    db.queue({ data: [row('a0300000-0000-4000-8000-000000000001', 'Chairs')], error: null });
    expect(await listCategories(ctx)).toEqual([
      row('a0300000-0000-4000-8000-000000000001', 'Chairs'),
    ]);
    expect(db.rpc).toHaveBeenCalledWith('list_categories');
  });

  it('creates a category and returns it by re-reading the list', async () => {
    const { db, ctx } = setup();
    const id = 'a0300000-0000-4000-8000-000000000001';
    db.queue({ data: id, error: null });
    db.queue({ data: [row(id, 'Chairs')], error: null });
    const created = await createCategory(ctx, { name: 'Chairs' });
    expect(created).toEqual(row(id, 'Chairs'));
    expect(db.rpc).toHaveBeenCalledWith('create_category', {
      p_name: 'Chairs',
      p_parent_id: null,
    });
  });

  it('updates and archives with the right rpc arguments', async () => {
    const { db, ctx } = setup();
    const id = 'a0300000-0000-4000-8000-000000000001';
    db.queue({ data: null, error: null });
    db.queue({ data: [row(id, 'Tables')], error: null });
    await updateCategory(ctx, id, { name: 'Tables' });
    expect(db.rpc).toHaveBeenCalledWith('update_category', {
      p_id: id,
      p_changes: { name: 'Tables' },
    });
    db.queue({ data: null, error: null });
    db.queue({ data: [row(id, 'Tables')], error: null });
    await setCategoryArchived(ctx, id, true, {
      move_to_category_id: 'a0300000-0000-4000-8000-000000000002',
    });
    expect(db.rpc).toHaveBeenCalledWith('set_category_archived', {
      p_id: id,
      p_archived: true,
      p_move_to: 'a0300000-0000-4000-8000-000000000002',
    });
  });

  it('throws the contract code when the database refuses', async () => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: 'CATEGORY_NAME_TAKEN: private detail' } });
    await expect(createCategory(ctx, { name: 'Chairs' })).rejects.toMatchObject({
      code: 'CATEGORY_NAME_TAKEN',
      statusCode: 409,
      message: 'Category name taken.',
    });
  });

  it.each([
    ['CATEGORY_NOT_FOUND', 404],
    ['CATEGORY_NAME_TAKEN', 409],
    ['CATEGORY_IN_USE', 409],
    ['CATEGORY_DEPTH', 400],
    ['CATEGORY_PARENT_ARCHIVED', 409],
  ] as const)('maps %s', (code, status) => {
    expect(mapDbError({ message: code + ': private detail' })).toMatchObject({
      code,
      statusCode: status,
    });
  });

  it('exposes the in-use counts and hides anything else', () => {
    const detail = { active_products: 2, active_children: 1 };
    expect(
      mapDbError({ message: 'CATEGORY_IN_USE', details: JSON.stringify(detail) })?.details,
    ).toEqual(detail);
    expect(
      mapDbError({
        message: 'CATEGORY_IN_USE',
        details: JSON.stringify({ ...detail, private: 'secret' }),
      })?.details,
    ).toBeUndefined();
  });
});
