import { describe, expect, it } from 'vitest';
import {
  DASHBOARD_TILES,
  DashboardApprovalsTile,
  DashboardCashTile,
  DashboardQuery,
  DashboardSalesTile,
  OwnerDashboard,
} from './dashboard.js';

const ID = '11111111-1111-4111-8111-111111111111';
const ts = '2026-10-21T10:00:00.000Z';

const tiles = {
  sales_today: {
    count: 5,
    total: '25000.00',
    paid_by_method: { cash: '4700.00', bank_transfer: '300.00', store_credit: '0.00' },
    on_contract: '20000.00',
  },
  collections_today: { count: 2, total: '1400.00', in_field: '400.00' },
  cash: {
    safes: '9500.00',
    banks: '0.00',
    drawers: '3000.00',
    wallets: '400.00',
    total_in_branches: '12900.00',
  },
  open_shifts: { count: 2, oldest_opened_at: ts, from_earlier_days: 1 },
  overdue: { contracts: 2, amount: '2600.00', customers: 2 },
  low_stock: { products: 5 },
  eta: { needs_action: 3, blocked: 1, send_failed: 1, rejected: 1, due_soon: 0, overdue: 0 },
  unclosed_days: { days: 1, branches: 1 },
  approvals: { discount: 2, purchase: 2, credit: 1, total: 5 },
};

const dashboard = { business_date: '2026-10-21', branch_id: null, generated_at: ts, tiles };

describe('D01 owner dashboard contract', () => {
  it('parses a full dashboard and a branch dashboard', () => {
    expect(OwnerDashboard.parse(dashboard).tiles.sales_today?.count).toBe(5);
    expect(OwnerDashboard.parse({ ...dashboard, branch_id: ID }).branch_id).toBe(ID);
  });

  it('has a nullable tile for every key, so a tile the caller cannot open is null', () => {
    expect(DASHBOARD_TILES).toHaveLength(9);
    const none = Object.fromEntries(DASHBOARD_TILES.map((k) => [k, null]));
    const parsed = OwnerDashboard.parse({ ...dashboard, tiles: none });
    for (const key of DASHBOARD_TILES) expect(parsed.tiles[key]).toBeNull();
    const { cash: _cash, ...missing } = tiles;
    expect(OwnerDashboard.safeParse({ ...dashboard, tiles: missing }).success).toBe(false);
  });

  it('keeps money as strings and counts as integers', () => {
    expect(DashboardSalesTile.safeParse({ ...tiles.sales_today, total: 25000 }).success).toBe(
      false,
    );
    expect(DashboardSalesTile.safeParse({ ...tiles.sales_today, total: 'abc' }).success).toBe(
      false,
    );
    expect(DashboardSalesTile.safeParse({ ...tiles.sales_today, count: 5.5 }).success).toBe(false);
    expect(DashboardSalesTile.safeParse({ ...tiles.sales_today, count: -1 }).success).toBe(false);
    expect(DashboardCashTile.safeParse({ ...tiles.cash, wallets: 400 }).success).toBe(false);
    expect(OwnerDashboard.safeParse({ ...dashboard, generated_at: '2026-10-21' }).success).toBe(
      false,
    );
    expect(OwnerDashboard.safeParse({ ...dashboard, business_date: '21/10/2026' }).success).toBe(
      false,
    );
  });

  it('allows an approval kind to be null without its key', () => {
    expect(
      DashboardApprovalsTile.parse({ discount: null, purchase: 1, credit: null, total: 1 })
        .purchase,
    ).toBe(1);
    expect(DashboardApprovalsTile.safeParse({ discount: 1, purchase: 1, credit: 1 }).success).toBe(
      false,
    );
  });

  it('has an empty open-shifts tile with no oldest time', () => {
    const empty = {
      ...tiles,
      open_shifts: { count: 0, oldest_opened_at: null, from_earlier_days: 0 },
    };
    expect(
      OwnerDashboard.parse({ ...dashboard, tiles: empty }).tiles.open_shifts?.oldest_opened_at,
    ).toBeNull();
  });

  it('accepts only a branch_id in the query, strictly', () => {
    expect(DashboardQuery.parse({})).toEqual({});
    expect(DashboardQuery.parse({ branch_id: ID })).toEqual({ branch_id: ID });
    expect(DashboardQuery.safeParse({ branch_id: 'x' }).success).toBe(false);
    expect(DashboardQuery.safeParse({ organization_id: ID }).success).toBe(false);
  });
});
