import { describe, expect, it } from 'vitest';
import { COLLECTION_NOT_REVERSIBLE_REASONS } from './collections.js';
import { Customer } from './customers.js';
import { errorCodeHttpStatus } from './errors.js';
import { OverdueListQuery } from './overdue.js';
import { PERMISSION_KEYS } from './permissions.js';
import {
  CollectorRoute,
  CollectorRouteQuery,
  FieldCollectionBody,
  MyWallet,
  SetCustomerCollectorBody,
  SettleWalletBody,
  WalletMovementPage,
  WalletMovementQuery,
  WalletSettlement,
} from './wallets.js';

const ID = '11111111-1111-4111-8111-111111111111';
const ID2 = '22222222-2222-4222-8222-222222222222';
const ts = '2026-10-19T08:00:00.000Z';

describe('N06 field collection body', () => {
  it('is the same body as a counter collection', () => {
    const body = {
      customer_id: ID,
      contracts: [{ contract_id: ID2, amount: '1000.00' }],
      payments: [{ method: 'cash', amount: '1000.00' }],
    };
    expect(FieldCollectionBody.safeParse(body).success).toBe(true);
    expect(FieldCollectionBody.safeParse({ ...body, shift_id: ID }).success).toBe(false);
    expect(FieldCollectionBody.safeParse({ ...body, payments: [] }).success).toBe(false);
  });
});

describe('N06 settle body', () => {
  const ok = { to_account_id: ID, handed: '900.00', expected_balance: '1500.00' };
  it('takes a partial settlement with no shortage', () => {
    expect(SettleWalletBody.safeParse(ok).success).toBe(true);
  });
  it('needs a reason for a shortage', () => {
    expect(SettleWalletBody.safeParse({ ...ok, shortage: '100.00' }).success).toBe(false);
    expect(SettleWalletBody.safeParse({ ...ok, shortage: '100.00', reason: 'ab' }).success).toBe(
      false,
    );
    expect(
      SettleWalletBody.safeParse({ ...ok, shortage: '100.00', reason: 'Torn note' }).success,
    ).toBe(true);
    expect(SettleWalletBody.safeParse({ ...ok, shortage: '0.00' }).success).toBe(true);
  });
  it('refuses handing in nothing, a negative amount and unknown keys', () => {
    expect(SettleWalletBody.safeParse({ ...ok, handed: '0.00' }).success).toBe(false);
    expect(SettleWalletBody.safeParse({ ...ok, handed: '-5.00' }).success).toBe(false);
    expect(SettleWalletBody.safeParse({ ...ok, handed: '10.005' }).success).toBe(false);
    expect(SettleWalletBody.safeParse({ ...ok, commission: '1.00' }).success).toBe(false);
  });
});

describe('N06 other bodies and queries', () => {
  it('assigns or clears a collector', () => {
    expect(SetCustomerCollectorBody.safeParse({ employee_id: ID }).success).toBe(true);
    expect(SetCustomerCollectorBody.safeParse({ employee_id: null }).success).toBe(true);
    expect(SetCustomerCollectorBody.safeParse({}).success).toBe(false);
    expect(SetCustomerCollectorBody.safeParse({ employee_id: ID, reason: 'ab' }).success).toBe(
      false,
    );
  });
  it('reads a route for a date and a ledger page', () => {
    expect(CollectorRouteQuery.safeParse({ employee_id: ID, date: '2026-10-19' }).success).toBe(
      true,
    );
    expect(CollectorRouteQuery.safeParse({ date: '2026-02-30' }).success).toBe(false);
    expect(WalletMovementQuery.parse({ limit: '10' }).limit).toBe(10);
    expect(WalletMovementQuery.safeParse({ limit: '1000' }).success).toBe(false);
    expect(OverdueListQuery.safeParse({ collector_id: ID }).success).toBe(true);
  });
});

describe('N06 answers', () => {
  it('parses an empty wallet and a wallet ledger page', () => {
    expect(
      MyWallet.safeParse({
        wallet: null,
        balance: '0.00',
        today: { count: 0, amount: '0.00', cash: '0.00' },
        oldest_unsettled_date: null,
        last_settlement: null,
      }).success,
    ).toBe(true);
    const row = {
      id: ID,
      name: 'Wallet',
      is_active: true,
      collector: { id: ID2, name: 'Collector' },
      branch_id: ID,
      branch_name: 'Main',
      balance: '500.00',
      oldest_unsettled_date: '2026-10-19',
      last_settlement: null,
    };
    expect(
      WalletMovementPage.safeParse({
        wallet: row,
        items: [
          {
            id: ID,
            business_date: '2026-10-19',
            created_at: ts,
            type: 'transfer_out',
            amount: '-900.00',
            balance_after: '600.00',
            source_type: 'cash_transfer',
            source_id: ID2,
            source_number: 'MAIN-CX-26-000001',
            note: null,
            created_by_name: 'Accountant',
            settlement: { handed: '900.00', shortage: '100.00', reason: 'Torn note' },
          },
        ],
        next_cursor: null,
      }).success,
    ).toBe(true);
    expect(
      WalletSettlement.safeParse({
        id: ID,
        number: 'MAIN-CX-26-000001',
        business_date: '2026-10-19',
        wallet_id: ID,
        wallet_name: 'Wallet',
        collector: { id: ID2, name: 'Collector' },
        to_account_id: ID2,
        to_account_name: 'Safe',
        handed: '900.00',
        shortage: '100.00',
        reason: 'Torn note',
        balance_after: '500.00',
        created_by_name: null,
        created_at: ts,
      }).success,
    ).toBe(true);
  });
  it('parses a route', () => {
    expect(
      CollectorRoute.safeParse({
        employee_id: ID,
        employee_name: 'Collector',
        date: '2026-10-19',
        stops: [
          {
            customer: { id: ID2, name: 'C', phone: null, address: null, city: 'Cairo' },
            amount_due: '1500.00',
            amount_overdue: '1000.00',
            max_days_late: 12,
            next_due_date: '2026-11-19',
            contracts: [{ id: ID, number: 'X', amount_due: '1500.00', amount_overdue: '1000.00' }],
          },
        ],
        totals: { customers: 1, amount_due: '1500.00', amount_overdue: '1000.00' },
      }).success,
    ).toBe(true);
  });
  it('a customer carries its collector (or null)', () => {
    const shape = Customer.shape;
    expect(shape.collector.safeParse(null).success).toBe(true);
    expect(shape.collector.safeParse({ id: ID, name: 'Collector' }).success).toBe(true);
  });
});

describe('N06 errors and keys', () => {
  it('maps the five new codes', () => {
    expect(errorCodeHttpStatus.CUSTOMER_NOT_ASSIGNED).toBe(403);
    expect(errorCodeHttpStatus.COLLECTOR_INVALID).toBe(422);
    expect(errorCodeHttpStatus.WALLET_BALANCE_CHANGED).toBe(409);
    expect(errorCodeHttpStatus.SELF_SETTLEMENT).toBe(403);
    expect(errorCodeHttpStatus.WALLET_NOT_FOUND).toBe(404);
  });
  it('adds handed_in to the reversal reasons and no permission key', () => {
    expect(COLLECTION_NOT_REVERSIBLE_REASONS).toContain('handed_in');
    expect(PERMISSION_KEYS).toContain('collector.settle');
    expect(PERMISSION_KEYS.some((k) => k.includes('commission'))).toBe(false);
  });
});
