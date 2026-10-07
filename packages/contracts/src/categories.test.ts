import { describe, it, expect } from 'vitest';
import {
  Category,
  CategoryArchiveBody,
  CategoryCreateBody,
  CategoryIdParams,
  CategoryInUseDetail,
  CategoryUpdateBody,
} from './categories';

const category = {
  id: 'a0300000-0000-4000-8000-000000000001',
  name: 'Chairs',
  parent_id: 'a0300000-0000-4000-8000-000000000002',
  archived_at: null,
  active_product_count: 4,
  created_at: '2026-10-07T08:00:00.000Z',
  updated_at: '2026-10-07T08:00:00.000Z',
};

describe('C01 category contracts', () => {
  it('parses a category and keeps counts as integers', () => {
    expect(Category.parse(category)).toMatchObject({
      name: 'Chairs',
      active_product_count: 4,
    });
    expect(Category.safeParse({ ...category, active_product_count: '4' }).success).toBe(false);
    expect(Category.safeParse({ ...category, active_product_count: -1 }).success).toBe(false);
  });

  it('trims the name and enforces the 1..60 limit', () => {
    expect(CategoryCreateBody.parse({ name: ' Chairs ' })).toMatchObject({
      name: 'Chairs',
    });
    expect(CategoryCreateBody.safeParse({ name: ' ' }).success).toBe(false);
    expect(CategoryCreateBody.safeParse({ name: 'x'.repeat(61) }).success).toBe(false);
    expect(CategoryCreateBody.safeParse({}).success).toBe(false);
  });

  it('forbids unknown keys everywhere', () => {
    expect(CategoryCreateBody.safeParse({ name: 'C', organization_id: 'x' }).success).toBe(false);
    expect(CategoryUpdateBody.safeParse({ name: 'C', sku: 'x' }).success).toBe(false);
    expect(CategoryIdParams.safeParse({ id: 'x', org: 'y' }).success).toBe(false);
    expect(CategoryArchiveBody.safeParse({ move_to: 'x' }).success).toBe(false);
  });

  it('accepts a nullable parent on create, requires a change on update', () => {
    expect(CategoryCreateBody.parse({ name: 'C', parent_id: null })).toMatchObject({
      parent_id: null,
    });
    expect(CategoryCreateBody.parse({ name: 'C', parent_id: category.id })).toMatchObject({
      parent_id: category.id,
    });
    expect(CategoryUpdateBody.safeParse({}).success).toBe(false);
    expect(CategoryUpdateBody.parse({ name: 'C' })).toMatchObject({ name: 'C' });
    expect(CategoryUpdateBody.parse({ parent_id: null })).toMatchObject({
      parent_id: null,
    });
  });

  it('validates the archive move target and the in-use detail', () => {
    expect(CategoryArchiveBody.parse({})).toEqual({});
    expect(CategoryArchiveBody.parse({ move_to_category_id: null })).toEqual({
      move_to_category_id: null,
    });
    expect(CategoryInUseDetail.parse({ active_products: 2, active_children: 0 })).toMatchObject({
      active_products: 2,
    });
    expect(
      CategoryInUseDetail.safeParse({ active_products: 2.5, active_children: 0 }).success,
    ).toBe(false);
    expect(CategoryInUseDetail.safeParse({ active_products: 2 }).success).toBe(false);
  });
});
