import { describe, it, expect } from 'vitest';
import {
  StockAdjustment,
  StockAdjustmentCreateBody,
  StockAdjustmentListQuery,
  StockCountCreateBody,
  StockCountDetail,
  StockCountDetailQuery,
  StockCountLinesBody,
  StockCountPostBody,
  StockCountScanBody,
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
      source_number: null,
      reason: null,
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

describe('I02 adjustment and count contracts', () => {
  const line = { product_id: ID, quantity: -2 };
  const body = { branch_id: ID, reason: 'damage', lines: [line] };

  it('an adjustment: reason, note, lines', () => {
    expect(StockAdjustmentCreateBody.parse({ ...body, note: '  ' })).toEqual({
      ...body,
      note: undefined,
    });
    expect(StockAdjustmentCreateBody.safeParse({ ...body, reason: 'count' }).success).toBe(false);
    expect(StockAdjustmentCreateBody.safeParse({ ...body, reason: 'other' }).success).toBe(false);
    expect(
      StockAdjustmentCreateBody.safeParse({ ...body, reason: 'other', note: 'Sample' }).success,
    ).toBe(true);
    expect(StockAdjustmentCreateBody.safeParse({ ...body, lines: [] }).success).toBe(false);
    expect(
      StockAdjustmentCreateBody.safeParse({ ...body, lines: [{ ...line, quantity: 0 }] }).success,
    ).toBe(false);
    expect(
      StockAdjustmentCreateBody.safeParse({ ...body, lines: [{ ...line, quantity: 1.5 }] }).success,
    ).toBe(false);
    expect(StockAdjustmentCreateBody.safeParse({ ...body, organization_id: ID }).success).toBe(
      false,
    );
  });

  it('the reason sets the direction; no duplicate lines', () => {
    const up = { ...line, quantity: 3 };
    expect(StockAdjustmentCreateBody.safeParse({ ...body, lines: [up] }).success).toBe(false);
    expect(
      StockAdjustmentCreateBody.safeParse({ ...body, reason: 'loss', lines: [up] }).success,
    ).toBe(false);
    expect(
      StockAdjustmentCreateBody.safeParse({ ...body, reason: 'found', lines: [line] }).success,
    ).toBe(false);
    expect(
      StockAdjustmentCreateBody.safeParse({ ...body, reason: 'found', lines: [up] }).success,
    ).toBe(true);
    expect(
      StockAdjustmentCreateBody.safeParse({ ...body, reason: 'correction', lines: [line, up] })
        .success,
    ).toBe(false);
    expect(
      StockAdjustmentCreateBody.safeParse({
        ...body,
        reason: 'correction',
        lines: [line, { ...up, unit_id: ID }],
      }).success,
    ).toBe(true);
  });

  it('an adjustment response and list query', () => {
    const adjustment = {
      id: ID,
      number: 'MAIN-SA-26-000001',
      branch_id: ID,
      reason: 'count',
      note: null,
      count_id: ID,
      count_number: 'MAIN-SC-26-000001',
      created_at: '2026-10-10T08:00:00.000Z',
      created_by_name: 'Owner',
      lines_count: 1,
      quantity_in: 0,
      quantity_out: 2,
      lines: [
        {
          id: ID,
          product_id: ID,
          name_ar: 'كابل',
          name_en: null,
          sku: 'CB',
          unit_id: null,
          serial: null,
          quantity: -2,
        },
      ],
    };
    expect(StockAdjustment.parse(adjustment)).toEqual(adjustment);
    expect(StockAdjustmentListQuery.parse({ reason: 'count' })).toMatchObject({
      reason: 'count',
      page: 1,
    });
    expect(StockAdjustmentListQuery.safeParse({ reason: 'gift' }).success).toBe(false);
  });

  it('count bodies', () => {
    expect(StockCountCreateBody.parse({ branch_id: ID })).toEqual({ branch_id: ID });
    expect(StockCountCreateBody.safeParse({ branch_id: ID, category_id: null }).success).toBe(true);
    expect(
      StockCountLinesBody.safeParse({ lines: [{ product_id: ID, counted_qty: null }] }).success,
    ).toBe(true);
    expect(
      StockCountLinesBody.safeParse({ lines: [{ product_id: ID, counted_qty: -1 }] }).success,
    ).toBe(false);
    expect(
      StockCountLinesBody.safeParse({
        lines: [
          { product_id: ID, counted_qty: 1 },
          { product_id: ID, counted_qty: 2 },
        ],
      }).success,
    ).toBe(false);
    expect(StockCountScanBody.parse({ code: ' SN-1 ' })).toEqual({ code: 'SN-1' });
    expect(StockCountScanBody.safeParse({ code: '  ' }).success).toBe(false);
    expect(StockCountPostBody.parse({})).toEqual({ uncounted_as_zero: false });
    expect(StockCountDetailQuery.parse({ filter: 'different' })).toMatchObject({
      filter: 'different',
      page: 1,
    });
    expect(StockCountDetailQuery.safeParse({ filter: 'odd' }).success).toBe(false);
  });

  it('a count with a page of lines', () => {
    const detail = {
      id: ID,
      number: 'MAIN-SC-26-000001',
      branch_id: ID,
      category_id: null,
      category_name: null,
      status: 'open',
      created_at: '2026-10-10T08:00:00.000Z',
      created_by_name: 'Keeper',
      posted_at: null,
      posted_by_name: null,
      adjustment_id: null,
      adjustment_number: null,
      lines_total: 1,
      lines_counted: 0,
      lines_different: 0,
      quantity_in: 0,
      quantity_out: 0,
      lines: {
        items: [
          {
            id: ID,
            product_id: ID,
            name_ar: 'موبايل',
            name_en: null,
            sku: 'PH',
            barcode: null,
            is_serialized: true,
            unit_id: ID,
            serial: 'SN-1',
            expected_qty: 1,
            counted_qty: null,
            difference: null,
          },
        ],
        page: 1,
        pageSize: 50,
        total: 1,
      },
    };
    expect(StockCountDetail.parse(detail)).toEqual(detail);
    expect(StockCountDetail.safeParse({ ...detail, status: 'draft' }).success).toBe(false);
  });
});
