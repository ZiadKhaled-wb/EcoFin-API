import { describe, expect, it } from 'vitest';
import { errorCodeHttpStatus } from './errors.js';
import {
  DismissReferralBody,
  HandleWarningBody,
  LegalReferralListQuery,
  OverdueAction,
  OverdueListPage,
  OverdueListQuery,
  OverdueRunResult,
  OverdueWarningListQuery,
} from './overdue.js';
import { PERMISSION_KEYS, ROLE_DEFAULT_PERMISSIONS } from './permissions.js';
import { InstallmentPolicyBody } from './settings.js';

const ID = '11111111-1111-4111-8111-111111111111';
const contract = { id: ID, number: 'BR1-CT-26-000001', frequency: 'monthly', branch_id: ID };
const customer = { id: ID, name: 'Nadia', phone: '01011112222', status: 'blocked' };

describe('N04 lists', () => {
  it('reads the query string filters', () => {
    expect(OverdueListQuery.parse({ min_days: '30', limit: '10' })).toEqual({
      min_days: 30,
      limit: 10,
    });
    expect(OverdueListQuery.safeParse({ collector_id: ID }).success).toBe(false);
    expect(OverdueListQuery.safeParse({ min_days: '0' }).success).toBe(false);
    expect(OverdueWarningListQuery.safeParse({ status: 'dismissed' }).success).toBe(false);
    expect(LegalReferralListQuery.safeParse({ status: 'dismissed' }).success).toBe(true);
  });

  it('parses a page with totals and has no fee field', () => {
    const page = {
      items: [
        {
          contract,
          customer,
          overdue_amount: '2000.00',
          overdue_lines: 2,
          max_days_late: 64,
          oldest_due_date: '2026-08-14',
          remaining: '9000.00',
          last_payment_at: null,
          open_warning: { id: ID, business_date: '2026-10-17' },
          legal_referral: { id: ID, status: 'open', business_date: '2026-10-17' },
        },
      ],
      next_cursor: null,
      totals: {
        contracts: 1,
        overdue_amount: '2000.00',
        late_1_30: '1000.00',
        late_31_60: '0.00',
        late_61_90: '1000.00',
        late_90_plus: '0.00',
      },
    };
    expect(OverdueListPage.safeParse(page).success).toBe(true);
    expect(JSON.stringify(Object.keys(OverdueListPage.shape.items.element.shape))).not.toMatch(
      /fee/,
    );
  });

  it('parses a warning record', () => {
    const warning = {
      id: ID,
      kind: 'warning',
      status: 'handled',
      business_date: '2026-10-17',
      days_late: 4,
      overdue_amount: '1000.00',
      contract,
      customer,
      current: { overdue_amount: '0.00', max_days_late: null },
      outcome: 'promised',
      note: 'Thursday',
      handled_at: '2026-10-17T10:00:00+03:00',
      handled_by_name: 'Collector',
      legal_case_id: null,
      created_at: '2026-10-17T00:30:00+03:00',
    };
    expect(OverdueAction.safeParse(warning).success).toBe(true);
  });
});

describe('N04 writes', () => {
  it('a warning needs a known outcome, and a note for other', () => {
    expect(HandleWarningBody.safeParse({ outcome: 'promised' }).success).toBe(true);
    expect(HandleWarningBody.safeParse({ outcome: 'shouted' }).success).toBe(false);
    expect(HandleWarningBody.safeParse({ outcome: 'other' }).success).toBe(false);
    expect(HandleWarningBody.safeParse({ outcome: 'other', note: 'Moved away' }).success).toBe(
      true,
    );
    expect(
      HandleWarningBody.safeParse({ outcome: 'contacted', note: 'x'.repeat(501) }).success,
    ).toBe(false);
  });

  it('a dismissal needs a reason of 3 to 300 characters', () => {
    expect(DismissReferralBody.safeParse({ reason: 'no' }).success).toBe(false);
    expect(DismissReferralBody.safeParse({ reason: 'Agreed a payment plan' }).success).toBe(true);
  });

  it('the run result is counts only', () => {
    expect(
      OverdueRunResult.safeParse({
        business_date: '2026-10-17',
        warnings_created: 0,
        warnings_resolved: 0,
        bans: 0,
        customers_blocked: 0,
        legal_referrals: 0,
      }).success,
    ).toBe(true);
  });
});

describe('N04 permissions, errors, no late fees', () => {
  it('adds overdue.view and overdue.handle with their default roles', () => {
    expect(PERMISSION_KEYS).toContain('overdue.view');
    expect(PERMISSION_KEYS).toContain('overdue.handle');
    for (const role of ['BRANCH_MANAGER', 'COLLECTOR', 'ACCOUNTANT', 'LAWYER'] as const) {
      expect(ROLE_DEFAULT_PERMISSIONS[role]).toContain('overdue.view');
    }
    for (const role of ['BRANCH_MANAGER', 'COLLECTOR'] as const) {
      expect(ROLE_DEFAULT_PERMISSIONS[role]).toContain('overdue.handle');
    }
    expect(ROLE_DEFAULT_PERMISSIONS.CASHIER).not.toContain('overdue.view');
  });

  it('has the three error codes', () => {
    expect(errorCodeHttpStatus.LATE_FEES_NOT_ALLOWED).toBe(422);
    expect(errorCodeHttpStatus.OVERDUE_ACTION_NOT_OPEN).toBe(409);
    expect(errorCodeHttpStatus.OVERDUE_ACTION_NOT_FOUND).toBe(404);
  });

  it('the policy body still accepts the late-fee fields as none (an older client keeps working)', () => {
    expect(
      InstallmentPolicyBody.safeParse({
        late_fee_type: 'none',
        late_fee_value: '0.00',
        late_fee_recurring: false,
        late_fee_cap: null,
        grace_days: 3,
      }).success,
    ).toBe(true);
    expect(InstallmentPolicyBody.safeParse({ grace_days: 3 }).success).toBe(true);
  });
});
