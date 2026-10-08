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
  StockTransfer,
  StockTransferCreateBody,
  StockTransferListQuery,
  StockTransferReceiveBody,
  StockTransferUpdateBody,
  StockMovementList,
  StockMovementsQuery,
  StockMovementExportBody,
  StockMovementExport,
  STOCK_MOVEMENT_EXPORT_LIMIT,
  ExportTooLargeDetail,
  StockRow,
  BranchMinLevelBody,
  BranchMinLevels,
  LowStockSummary,
  LowStockSummaryQuery,
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
  min_source: 'shop',
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

  const movement = {
    id: ID,
    created_at: '2026-10-09T08:00:00.000Z',
    business_date: '2026-10-09',
    product_id: ID,
    product_name_ar: 'تلفزيون',
    product_name_en: null,
    sku: 'TV-1',
    branch_id: ID,
    unit_id: null,
    serial: null,
    type: 'purchase_in',
    stock_state: 'sellable',
    quantity: 10,
    balance_after: 10,
    source_type: 'purchase_invoice',
    source_id: ID,
    source_number: 'MAIN-PI-26-000001',
    party: 'Supplier',
    reason: null,
    reverses_movement_id: null,
    created_by_name: 'Owner',
  };

  it('I05 movement filters: everything optional, serial upper-cased, types as a list', () => {
    expect(StockMovementsQuery.parse({})).toMatchObject({ page: 1, pageSize: 50 });
    expect(StockMovementsQuery.parse({ product_id: ID })).toMatchObject({ product_id: ID });
    expect(
      StockMovementsQuery.parse({
        serial: ' imei-1 ',
        types: 'sale_out, delivery_out',
        from: '2026-10-01',
        to: '2026-10-09',
      }),
    ).toMatchObject({
      serial: 'IMEI-1',
      types: ['sale_out', 'delivery_out'],
      from: '2026-10-01',
      to: '2026-10-09',
    });
    expect(StockMovementsQuery.parse({ serial: '   ', types: '' })).toMatchObject({
      serial: undefined,
      types: undefined,
    });
    expect(StockMovementsQuery.safeParse({ types: 'sale_out,gift' }).success).toBe(false);
    expect(StockMovementsQuery.safeParse({ from: '2026-10-09', to: '2026-10-01' }).success).toBe(
      false,
    );
    expect(StockMovementsQuery.safeParse({ from: '2026-02-30' }).success).toBe(false);
    expect(StockMovementsQuery.safeParse({ serial: 'A'.repeat(65) }).success).toBe(false);
    expect(StockMovementsQuery.safeParse({ organization_id: ID }).success).toBe(false);
  });

  it('a movement carries its product, unit and source document', () => {
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

  it('I05 export: the same filters in a body, at most the export limit', () => {
    expect(StockMovementExportBody.parse({ types: ['adjustment'], serial: 'sn-1' })).toEqual({
      types: ['adjustment'],
      serial: 'SN-1',
    });
    expect(StockMovementExportBody.safeParse({ types: ['gift'] }).success).toBe(false);
    expect(StockMovementExportBody.safeParse({ page: 1 }).success).toBe(false);
    expect(
      StockMovementExportBody.safeParse({ from: '2026-10-09', to: '2026-10-01' }).success,
    ).toBe(false);
    expect(StockMovementExport.parse({ items: [movement], total: 1 }).total).toBe(1);
    expect(STOCK_MOVEMENT_EXPORT_LIMIT).toBe(10_000);
    expect(ExportTooLargeDetail.parse({ total: 10_001, limit: 10_000 })).toEqual({
      total: 10_001,
      limit: 10_000,
    });
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

describe('I03 transfer contracts', () => {
  const OTHER = 'a0800000-0000-4000-8000-000000000002';
  const body = {
    from_branch_id: ID,
    to_branch_id: OTHER,
    lines: [{ product_id: ID, quantity: 2 }],
  };

  it('a draft: two different branches, positive quantities, no duplicates, strict', () => {
    expect(StockTransferCreateBody.parse({ ...body, notes: '  ' })).toEqual({
      ...body,
      notes: undefined,
    });
    expect(StockTransferCreateBody.safeParse({ ...body, to_branch_id: ID }).success).toBe(false);
    expect(
      StockTransferCreateBody.safeParse({ ...body, lines: [{ product_id: ID, quantity: 0 }] })
        .success,
    ).toBe(false);
    expect(
      StockTransferCreateBody.safeParse({ ...body, lines: [...body.lines, ...body.lines] }).success,
    ).toBe(false);
    expect(StockTransferCreateBody.safeParse({ ...body, organization_id: ID }).success).toBe(false);
    expect(StockTransferUpdateBody.safeParse({ lines: body.lines }).success).toBe(true);
    expect(StockTransferUpdateBody.safeParse({ lines: [] }).success).toBe(false);
  });

  it('a receipt lists only the shortages, each with loss or damage', () => {
    expect(StockTransferReceiveBody.parse({})).toEqual({ lines: [] });
    const short = { line_id: ID, qty_received: 1, reason: 'loss' };
    expect(StockTransferReceiveBody.safeParse({ lines: [short] }).success).toBe(true);
    expect(
      StockTransferReceiveBody.safeParse({ lines: [{ ...short, reason: 'gift' }] }).success,
    ).toBe(false);
    expect(StockTransferReceiveBody.safeParse({ lines: [short, short] }).success).toBe(false);
    expect(
      StockTransferReceiveBody.safeParse({ lines: [{ ...short, qty_received: -1 }] }).success,
    ).toBe(false);
  });

  it('a transfer with lines and its receipt adjustments', () => {
    const transfer = {
      id: ID,
      number: 'MAIN-TR-26-000001',
      from_branch_id: ID,
      to_branch_id: OTHER,
      from_branch_name: 'Main',
      to_branch_name: 'Second',
      status: 'partially_received',
      notes: null,
      created_at: '2026-10-10T08:00:00.000Z',
      created_by_name: 'Keeper',
      sent_at: '2026-10-10T08:05:00.000Z',
      sent_by_name: 'Keeper',
      received_at: '2026-10-10T09:00:00.000Z',
      received_by_name: 'Receiver',
      lines_count: 1,
      quantity_sent: 6,
      quantity_received: 5,
      adjustments: [{ id: ID, number: 'I2-SA-26-000001', reason: 'loss' }],
      lines: [
        {
          id: ID,
          product_id: ID,
          name_ar: 'كابل',
          name_en: null,
          sku: 'CB',
          is_serialized: false,
          unit_id: null,
          serial: null,
          qty_sent: 6,
          qty_received: 5,
          discrepancy_reason: 'loss',
        },
      ],
    };
    expect(StockTransfer.parse(transfer)).toEqual(transfer);
    expect(StockTransferListQuery.parse({ status: 'sent' })).toMatchObject({
      status: 'sent',
      page: 1,
    });
    expect(StockTransferListQuery.safeParse({ status: 'lost' }).success).toBe(false);
  });
});

describe('I06 low-stock contracts', () => {
  it('a stock row says where its min level comes from', () => {
    expect(StockRow.parse({ ...row, min_source: 'branch' }).min_source).toBe('branch');
    expect(StockRow.safeParse({ ...row, min_source: 'global' }).success).toBe(false);
  });

  it('a branch level: 0 to 1 000 000, or null to remove it', () => {
    expect(BranchMinLevelBody.parse({ branch_id: ID, min_stock: 0 })).toEqual({
      branch_id: ID,
      min_stock: 0,
    });
    expect(BranchMinLevelBody.parse({ branch_id: ID, min_stock: null }).min_stock).toBeNull();
    for (const min_stock of [-1, 1_000_001, 1.5, '3'])
      expect(BranchMinLevelBody.safeParse({ branch_id: ID, min_stock }).success).toBe(false);
    expect(BranchMinLevelBody.safeParse({ branch_id: ID }).success).toBe(false);
    expect(
      BranchMinLevelBody.safeParse({ branch_id: ID, min_stock: 1, organization_id: ID }).success,
    ).toBe(false);
    expect(
      BranchMinLevels.parse({
        product_id: ID,
        product_min_stock: 0,
        shop_min_stock: 3,
        branches: [{ branch_id: ID, min_stock: null, min_level: 3, min_source: 'shop' }],
      }).branches[0]!.min_source,
    ).toBe('shop');
  });

  it('the dashboard summary: limit 1-20 (default 5), positive shortages', () => {
    expect(LowStockSummaryQuery.parse({})).toEqual({ limit: 5 });
    expect(LowStockSummaryQuery.parse({ limit: '20' })).toEqual({ limit: 20 });
    expect(LowStockSummaryQuery.safeParse({ limit: '21' }).success).toBe(false);
    const item = {
      product_id: ID,
      name_ar: 'كابل',
      name_en: null,
      sku: 'CB-1',
      branch_id: ID,
      available: 2,
      min_level: 10,
      shortage: 8,
    };
    expect(
      LowStockSummary.parse({ total: 1, branches: [{ branch_id: ID, low: 1 }], items: [item] })
        .items,
    ).toHaveLength(1);
    expect(
      LowStockSummary.safeParse({ total: 1, branches: [], items: [{ ...item, shortage: 0 }] })
        .success,
    ).toBe(false);
  });
});
