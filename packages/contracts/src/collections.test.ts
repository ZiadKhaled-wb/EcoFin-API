import { describe, expect, it } from 'vitest';
import {
  CollectionBody,
  CollectionNotReversibleDetail,
  CollectionPreviewQuery,
  CollectionReverseBody,
  ContractListQuery,
} from './collections.js';
import { errorCodeHttpStatus } from './errors.js';
import { PERMISSION_KEYS, ROLE_DEFAULT_PERMISSIONS } from './permissions.js';

const C1 = '11111111-1111-4111-8111-111111111111';
const C2 = '22222222-2222-4222-8222-222222222222';
const CUSTOMER = '33333333-3333-4333-8333-333333333333';
const BANK = '44444444-4444-4444-8444-444444444444';

const body = (over: Record<string, unknown> = {}) => ({
  customer_id: CUSTOMER,
  contracts: [{ contract_id: C1, amount: '1000.00' }],
  payments: [{ method: 'cash', amount: '1000.00' }],
  ...over,
});

describe('N03 CollectionBody', () => {
  it('takes one contract paid in cash', () => {
    expect(CollectionBody.safeParse(body()).success).toBe(true);
  });

  it('takes several contracts split over cash and bank transfers', () => {
    const ok = body({
      contracts: [
        { contract_id: C1, amount: '1000.00', expected_remaining: '11000.00' },
        { contract_id: C2, amount: '500.00' },
      ],
      payments: [
        { method: 'cash', amount: '1200.00', tendered: '1250.00' },
        { method: 'bank_transfer', amount: '300.00', cash_account_id: BANK, reference: 'TRX-1' },
      ],
    });
    expect(CollectionBody.safeParse(ok).success).toBe(true);
  });

  it.each([
    ['store credit', { payments: [{ method: 'store_credit', amount: '1000.00' }] }],
    ['lines that do not add up', { payments: [{ method: 'cash', amount: '999.99' }] }],
    [
      'two cash lines',
      {
        payments: [
          { method: 'cash', amount: '500.00' },
          { method: 'cash', amount: '500.00' },
        ],
      },
    ],
    [
      'a contract twice',
      {
        contracts: [
          { contract_id: C1, amount: '500.00' },
          { contract_id: C1, amount: '500.00' },
        ],
      },
    ],
    [
      'amount 0',
      {
        contracts: [{ contract_id: C1, amount: '0.00' }],
        payments: [{ method: 'cash', amount: '0.00' }],
      },
    ],
    [
      'tendered below the amount',
      { payments: [{ method: 'cash', amount: '1000.00', tendered: '900.00' }] },
    ],
    ['an unknown field', { overpay: true }],
    ['no contract', { contracts: [] }],
  ])('refuses %s', (_name, over) => {
    expect(CollectionBody.safeParse(body(over)).success).toBe(false);
  });

  it('refuses five payment lines', () => {
    const lines = Array.from({ length: 5 }, (_, i) => ({
      method: 'bank_transfer',
      amount: '200.00',
      cash_account_id: BANK,
      reference: `R${i}`,
    }));
    expect(CollectionBody.safeParse(body({ payments: lines })).success).toBe(false);
  });
});

describe('N03 other inputs', () => {
  it('a reversal needs a reason of 3-500 characters', () => {
    expect(CollectionReverseBody.safeParse({ reason: 'changed mind' }).success).toBe(true);
    expect(CollectionReverseBody.safeParse({ reason: '  ' }).success).toBe(false);
  });

  it('the preview amount is positive money', () => {
    expect(CollectionPreviewQuery.safeParse({ amount: '2500.00' }).success).toBe(true);
    expect(CollectionPreviewQuery.safeParse({ amount: '0' }).success).toBe(false);
  });

  it('the contract list reads its query strings', () => {
    expect(ContractListQuery.parse({ q: 'CT', overdue: 'true', limit: '10' })).toEqual({
      q: 'CT',
      overdue: true,
      limit: 10,
    });
    expect(ContractListQuery.safeParse({ status: 'open' }).success).toBe(true);
    expect(ContractListQuery.safeParse({ status: 'late' }).success).toBe(false);
  });

  it('the reversal refusal names its reason', () => {
    expect(
      CollectionNotReversibleDetail.safeParse({ reason: 'not_latest', contract_id: C1 }).success,
    ).toBe(true);
    expect(CollectionNotReversibleDetail.safeParse({ reason: 'later' }).success).toBe(false);
  });
});

describe('N03 codes and permission', () => {
  it('maps the new codes', () => {
    expect(errorCodeHttpStatus.CONTRACT_NOT_OPEN).toBe(409);
    expect(errorCodeHttpStatus.COLLECTION_DUE_CHANGED).toBe(409);
    expect(errorCodeHttpStatus.COLLECTION_EXCEEDS_REMAINING).toBe(409);
    expect(errorCodeHttpStatus.COLLECTION_NOT_REVERSIBLE).toBe(409);
    expect(errorCodeHttpStatus.COLLECTION_NOT_FOUND).toBe(404);
  });

  it('collection.reverse: owner and branch manager by default, not a cashier', () => {
    expect(PERMISSION_KEYS).toContain('collection.reverse');
    expect(ROLE_DEFAULT_PERMISSIONS.OWNER).toContain('collection.reverse');
    expect(ROLE_DEFAULT_PERMISSIONS.BRANCH_MANAGER).toContain('collection.reverse');
    expect(ROLE_DEFAULT_PERMISSIONS.CASHIER).not.toContain('collection.reverse');
  });
});
