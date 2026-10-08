import { describe, it, expect } from 'vitest';
import {
  StockList,
  StockListQuery,
  StockMovementList,
  StockMovementsQuery,
  StockRow,
} from './stock.js';

const ID = 'a0800000-0000-4000-8000-000000000001';
const row = {
  product_id: ID,
  name_ar: 'تلفزيون',
  name_en: null,
  sku: 'TV-55',
  barcode: '2000000000015',
  category_id: null,
  is_serialized: false,
  archived_at: null,
  branch_id: ID,
  on_hand: 5,
  reserved: 2,
  available: 3,
  damaged: 1,
  in_transit: 0,
  min_level: 3,
  low: false,
};

describe('I01 stock contracts', () => {
  it('parses a stock row with integer quantities', () => {
    expect(StockRow.parse(row)).toEqual(row);
    expect(StockRow.safeParse({ ...row, on_hand: '5' }).success).toBe(false);
    expect(StockRow.safeParse({ ...row, reserved: -1 }).success).toBe(false);
    expect(StockList.parse({ items: [row], page: 1, pageSize: 50, total: 1 }).items).toHaveLength(
      1,
    );
  });

  it('list query defaults: with subcategories, not low only, first page', () => {
    expect(StockListQuery.parse({})).toEqual({
      page: 1,
      pageSize: 50,
      include_subcategories: true,
      low_only: false,
      search: undefined,
    });
    expect(
      StockListQuery.parse({ low_only: 'true', include_subcategories: 'false', search: ' tv ' }),
    ).toMatchObject({ low_only: true, include_subcategories: false, search: 'tv' });
    expect(StockListQuery.safeParse({ low_only: 'yes' }).success).toBe(false);
    expect(StockListQuery.safeParse({ branch_id: 'nope' }).success).toBe(false);
    expect(StockListQuery.safeParse({ organization_id: ID }).success).toBe(false);
    expect(StockListQuery.safeParse({ pageSize: '101' }).success).toBe(false);
  });

  it('movements need a product; branch is optional', () => {
    expect(StockMovementsQuery.parse({ product_id: ID })).toMatchObject({
      product_id: ID,
      page: 1,
    });
    expect(StockMovementsQuery.safeParse({}).success).toBe(false);
    const movement = {
      id: ID,
      created_at: '2026-10-09T08:00:00.000Z',
      business_date: '2026-10-09',
      branch_id: ID,
      type: 'purchase_in',
      stock_state: 'sellable',
      quantity: 10,
      balance_after: 10,
      serial: null,
      source_type: 'purchase_invoice',
      source_id: ID,
      reverses_movement_id: null,
      created_by_name: 'Owner',
    };
    expect(
      StockMovementList.parse({ items: [movement], page: 1, pageSize: 50, total: 1 }).items[0],
    ).toEqual(movement);
    expect(
      StockMovementList.safeParse({
        items: [{ ...movement, type: 'gift' }],
        page: 1,
        pageSize: 50,
        total: 1,
      }).success,
    ).toBe(false);
  });
});
