import { describe, expect, it } from 'vitest';
import { COLLECTION_NOT_REVERSIBLE_REASONS } from './collections.js';
import {
  ContractChange,
  ContractChangeListQuery,
  RescheduleBody,
  ReschedulePreviewBody,
  SettleBody,
  WaiverTooHighDetail,
  WriteOffBody,
} from './contractChanges.js';
import { CustomerStatementKind } from './customerAccount.js';
import { errorCodeHttpStatus } from './errors.js';

const ID = '11111111-1111-4111-8111-111111111111';
const settle = {
  waiver: '500.00',
  reason: 'Paid everything early',
  expected_remaining: '11000.00',
  payments: [{ method: 'cash', amount: '10500.00' }],
};

describe('N05 settlement body', () => {
  it('accepts payments that add up to the payoff minus the waiver', () => {
    expect(SettleBody.safeParse(settle).success).toBe(true);
    expect(
      SettleBody.safeParse({
        ...settle,
        payments: [
          { method: 'cash', amount: '500.00' },
          { method: 'bank_transfer', amount: '10000.00', cash_account_id: ID, reference: 'TRX-1' },
        ],
      }).success,
    ).toBe(true);
  });

  it('refuses a waiver without a reason, a short payment, a negative waiver and unknown keys', () => {
    expect(SettleBody.safeParse({ ...settle, reason: undefined }).success).toBe(false);
    expect(
      SettleBody.safeParse({
        ...settle,
        waiver: '0.00',
        reason: undefined,
        payments: [{ method: 'cash', amount: '11000.00' }],
      }).success,
    ).toBe(true);
    expect(
      SettleBody.safeParse({ ...settle, payments: [{ method: 'cash', amount: '11000.00' }] })
        .success,
    ).toBe(false);
    expect(SettleBody.safeParse({ ...settle, waiver: '-1.00' }).success).toBe(false);
    expect(SettleBody.safeParse({ ...settle, discount: '1.00' }).success).toBe(false);
  });
});

describe('N05 reschedule and write-off bodies', () => {
  const plan = { installments_count: 6, frequency: 'monthly', first_due_date: '2026-11-18' };
  it('checks the plan, the reason and the expected remaining', () => {
    expect(ReschedulePreviewBody.safeParse(plan).success).toBe(true);
    expect(ReschedulePreviewBody.safeParse({ ...plan, installments_count: 0 }).success).toBe(false);
    expect(ReschedulePreviewBody.safeParse({ ...plan, frequency: 'yearly' }).success).toBe(false);
    expect(
      RescheduleBody.safeParse({ ...plan, reason: 'Lost his job', expected_remaining: '1.00' })
        .success,
    ).toBe(true);
    expect(RescheduleBody.safeParse({ ...plan, expected_remaining: '1.00' }).success).toBe(false);
    expect(WriteOffBody.safeParse({ reason: 'ab', expected_remaining: '1.00' }).success).toBe(
      false,
    );
    expect(
      WriteOffBody.safeParse({ reason: 'Gone abroad', expected_remaining: '1.00' }).success,
    ).toBe(true);
  });

  it('reads the list filters', () => {
    expect(ContractChangeListQuery.parse({ kind: 'write_off', limit: '5' })).toEqual({
      kind: 'write_off',
      limit: 5,
    });
    expect(
      ContractChangeListQuery.safeParse({ from: '2026-10-20', to: '2026-10-01' }).success,
    ).toBe(false);
    expect(ContractChangeListQuery.safeParse({ kind: 'fee' }).success).toBe(false);
  });
});

describe('N05 answers and errors', () => {
  it('parses a change row, the new error, reasons and statement kinds', () => {
    expect(
      ContractChange.safeParse({
        id: ID,
        kind: 'write_off',
        contract_id: ID,
        old_version: 1,
        new_version: null,
        amount: '11000.00',
        principal_amount: '9166.67',
        profit_amount: '1833.33',
        profit_waived: '0.00',
        reason: 'Gone abroad',
        business_date: '2026-10-18',
        created_at: '2026-10-18T08:00:00.000Z',
        created_by: { id: ID, name: 'Owner' },
        approved_by: ID,
        payment_id: null,
      }).success,
    ).toBe(true);
    expect(errorCodeHttpStatus.WAIVER_TOO_HIGH).toBe(422);
    expect(WaiverTooHighDetail.parse({ max_waiver: '1.00' })).toEqual({ max_waiver: '1.00' });
    expect(COLLECTION_NOT_REVERSIBLE_REASONS).toContain('settlement');
    expect(COLLECTION_NOT_REVERSIBLE_REASONS).toContain('contract_changed');
    expect(CustomerStatementKind.options).toEqual(
      expect.arrayContaining(['profit_waiver', 'write_off']),
    );
  });
});
