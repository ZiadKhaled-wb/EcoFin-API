import { describe, it, expect } from 'vitest';
import {
  CREDIT_AMOUNT_MAX,
  CREDIT_EXCEPTION_VALID_HOURS,
  CreditBehaviour,
  CreditCheck,
  CreditCheckQuery,
  CreditException,
  CreditExceptionDecideBody,
  CreditExceptionIdParams,
  CreditExceptionList,
  CreditExceptionListQuery,
  CreditExceptionRequestBody,
  CreditLimitBody,
  CreditLimitExceededDetail,
  CreditProfile,
  CreditReason,
  CreditScoreComponent,
} from './credit.js';
import { errorCodeHttpStatus } from './errors.js';

const ID = 'a0730000-0000-4000-8000-000000000001';
const OTHER = 'a0730000-0000-4000-8000-000000000002';
const AT = '2026-10-16T09:00:00.123456+00:00';

const components = [
  { key: 'guarantors', weight: 40, value: 1, points: 40 },
  { key: 'income', weight: 30, value: 1, points: 30 },
  { key: 'residence', weight: 20, value: 0, points: 0 },
  { key: 'identity', weight: 10, value: 0.5, points: 5 },
];
const behaviour = {
  due_lines: 3,
  on_time_pct: 33,
  max_days_late: 10,
  current_overdue_amount: '1000.00',
  overdue_lines: 1,
  open_contracts: 1,
  completed_contracts: 0,
};
const profile = {
  customer_id: ID,
  status: 'active',
  credit_limit: '20000.00',
  suggested_limit: '24000.00',
  exposure: '14000.00',
  available: '6000.00',
  over_limit_by: '0.00',
  score: 75,
  min_score: 50,
  components,
  behaviour,
  store_credit: '0.00',
  limit_history: [{ at: AT, by_name: 'Owner', from: '0.00', to: '20000.00', reason: 'Good payer' }],
  latest_survey: null,
};
const exception = {
  id: ID,
  status: 'pending',
  customer_id: OTHER,
  customer_name: 'Exposure Customer',
  financed_amount: '8000.00',
  reasons: ['limit'],
  reason: 'New fridge',
  snapshot: {
    limit: '20000.00',
    exposure: '14000.00',
    available: '6000.00',
    score: 75,
    min_score: 50,
  },
  requested_by_name: 'Cashier',
  requested_at: AT,
  mine: true,
  decided_by_name: null,
  decided_at: null,
  decision_note: null,
  expires_at: null,
  used: false,
};

describe('constants', () => {
  it('names the limit maximum and the exception lifetime', () => {
    expect(CREDIT_AMOUNT_MAX).toBe('99999999.99');
    expect(CREDIT_EXCEPTION_VALID_HOURS).toBe(24);
  });
});

describe('CreditReason and CreditScoreComponent', () => {
  it('knows the three reasons only', () => {
    expect(CreditReason.options).toEqual(['limit', 'score', 'watch']);
    expect(CreditReason.safeParse('blocked').success).toBe(false);
  });
  it('accepts the four components and refuses a value above 1 or an unknown key', () => {
    for (const c of components) expect(CreditScoreComponent.safeParse(c).success).toBe(true);
    expect(CreditScoreComponent.safeParse({ ...components[0], value: 1.5 }).success).toBe(false);
    expect(CreditScoreComponent.safeParse({ ...components[0], key: 'survey' }).success).toBe(false);
  });
});

describe('CreditBehaviour', () => {
  it('accepts the numbers and the nulls of a customer with nothing due', () => {
    expect(CreditBehaviour.safeParse(behaviour).success).toBe(true);
    expect(
      CreditBehaviour.safeParse({
        ...behaviour,
        due_lines: 0,
        on_time_pct: null,
        max_days_late: null,
        current_overdue_amount: '0.00',
        overdue_lines: 0,
      }).success,
    ).toBe(true);
  });
  it('refuses a percentage above 100 and negative days', () => {
    expect(CreditBehaviour.safeParse({ ...behaviour, on_time_pct: 101 }).success).toBe(false);
    expect(CreditBehaviour.safeParse({ ...behaviour, max_days_late: -1 }).success).toBe(false);
  });
});

describe('CreditProfile', () => {
  it('accepts a profile and a null suggested limit', () => {
    expect(CreditProfile.safeParse(profile).success).toBe(true);
    expect(CreditProfile.safeParse({ ...profile, suggested_limit: null }).success).toBe(true);
  });
  it('wants exactly four components, a known status and at most ten history rows', () => {
    expect(
      CreditProfile.safeParse({ ...profile, components: components.slice(0, 3) }).success,
    ).toBe(false);
    expect(CreditProfile.safeParse({ ...profile, status: 'frozen' }).success).toBe(false);
    const row = profile.limit_history[0];
    expect(
      CreditProfile.safeParse({ ...profile, limit_history: Array(11).fill(row) }).success,
    ).toBe(false);
  });
  it('refuses a score above 100 and money that is a number', () => {
    expect(CreditProfile.safeParse({ ...profile, score: 101 }).success).toBe(false);
    expect(CreditProfile.safeParse({ ...profile, exposure: 14000 }).success).toBe(false);
  });
});

describe('CreditLimitBody', () => {
  it('accepts 0, a limit with pence and the maximum, with or without a reason', () => {
    expect(CreditLimitBody.parse({ credit_limit: '0' })).toEqual({ credit_limit: '0' });
    expect(
      CreditLimitBody.safeParse({ credit_limit: '15000.50', reason: 'Good payer' }).success,
    ).toBe(true);
    expect(CreditLimitBody.safeParse({ credit_limit: CREDIT_AMOUNT_MAX }).success).toBe(true);
  });
  it('trims the reason', () => {
    expect(CreditLimitBody.parse({ credit_limit: '10', reason: '  Slow  ' }).reason).toBe('Slow');
  });
  it('refuses negative, too big, three decimals, a number and unknown keys', () => {
    for (const credit_limit of ['-1', '100000000', '99999999.991', '', 'abc'])
      expect(CreditLimitBody.safeParse({ credit_limit }).success).toBe(false);
    expect(CreditLimitBody.safeParse({ credit_limit: 100 }).success).toBe(false);
    expect(CreditLimitBody.safeParse({ credit_limit: '100', organization_id: ID }).success).toBe(
      false,
    );
    expect(
      CreditLimitBody.safeParse({ credit_limit: '100', reason: 'r'.repeat(301) }).success,
    ).toBe(false);
  });
});

describe('CreditCheckQuery', () => {
  it('wants an amount above zero', () => {
    expect(CreditCheckQuery.safeParse({ financed_amount: '6000.01' }).success).toBe(true);
    expect(CreditCheckQuery.safeParse({ financed_amount: '0.01' }).success).toBe(true);
    for (const financed_amount of ['0', '0.00', '-5', '100000000', '1.234', ''])
      expect(CreditCheckQuery.safeParse({ financed_amount }).success).toBe(false);
    expect(CreditCheckQuery.safeParse({}).success).toBe(false);
    expect(CreditCheckQuery.safeParse({ financed_amount: '10', x: 1 }).success).toBe(false);
  });
});

describe('CreditCheck', () => {
  const check = {
    allowed: false,
    reasons: ['limit', 'score'],
    needs_approval: true,
    limit: '20000.00',
    exposure: '14000.00',
    available: '6000.00',
    score: 40,
    min_score: 50,
    pending_approval_id: null,
    approved_approval_id: OTHER,
  };
  it('accepts the preview with or without approval ids', () => {
    expect(CreditCheck.safeParse(check).success).toBe(true);
    expect(
      CreditCheck.safeParse({ ...check, reasons: [], allowed: true, needs_approval: false })
        .success,
    ).toBe(true);
    expect(CreditCheck.safeParse({ ...check, pending_approval_id: ID }).success).toBe(true);
  });
  it('refuses an unknown reason', () => {
    expect(CreditCheck.safeParse({ ...check, reasons: ['blocked'] }).success).toBe(false);
  });
});

describe('credit exceptions', () => {
  it('accepts a pending, an approved and a used exception', () => {
    expect(CreditException.safeParse(exception).success).toBe(true);
    expect(
      CreditException.safeParse({
        ...exception,
        status: 'approved',
        mine: false,
        decided_by_name: 'Manager',
        decided_at: AT,
        decision_note: 'Known customer',
        expires_at: '2026-10-17T09:00:00.123456+00:00',
        used: true,
      }).success,
    ).toBe(true);
  });
  it('refuses an unknown status and a score out of range in the snapshot', () => {
    expect(CreditException.safeParse({ ...exception, status: 'expired' }).success).toBe(false);
    expect(
      CreditException.safeParse({ ...exception, snapshot: { ...exception.snapshot, score: 120 } })
        .success,
    ).toBe(false);
  });
  it('wraps the list in items', () => {
    expect(CreditExceptionList.safeParse({ items: [exception] }).success).toBe(true);
    expect(CreditExceptionList.safeParse([exception]).success).toBe(false);
  });
  it('lists pending by default and knows every status', () => {
    expect(CreditExceptionListQuery.parse({})).toEqual({ status: 'pending' });
    for (const status of ['pending', 'approved', 'rejected', 'cancelled', 'all'])
      expect(CreditExceptionListQuery.safeParse({ status }).success).toBe(true);
    expect(CreditExceptionListQuery.safeParse({ status: 'used' }).success).toBe(false);
    expect(CreditExceptionListQuery.safeParse({ status: 'all', x: 1 }).success).toBe(false);
  });
  it('requests with an amount above zero and a reason (checked by the database: 3-300)', () => {
    expect(
      CreditExceptionRequestBody.parse({ financed_amount: '8000.00', reason: '  New fridge ' }),
    ).toEqual({
      financed_amount: '8000.00',
      reason: 'New fridge',
    });
    expect(
      CreditExceptionRequestBody.safeParse({ financed_amount: '0', reason: 'x' }).success,
    ).toBe(false);
    expect(CreditExceptionRequestBody.safeParse({ financed_amount: '10' }).success).toBe(false);
    expect(
      CreditExceptionRequestBody.safeParse({ financed_amount: '10', reason: 'r', customer_id: ID })
        .success,
    ).toBe(false);
    expect(
      CreditExceptionRequestBody.safeParse({ financed_amount: '10', reason: 'r'.repeat(301) })
        .success,
    ).toBe(false);
  });
  it('decides with a boolean and an optional trimmed note', () => {
    expect(CreditExceptionDecideBody.parse({ approve: true })).toEqual({ approve: true });
    expect(CreditExceptionDecideBody.parse({ approve: false, note: '  Too much ' })).toEqual({
      approve: false,
      note: 'Too much',
    });
    expect(CreditExceptionDecideBody.safeParse({ approve: 'yes' }).success).toBe(false);
    expect(
      CreditExceptionDecideBody.safeParse({ approve: true, note: 'n'.repeat(501) }).success,
    ).toBe(false);
    expect(CreditExceptionDecideBody.safeParse({ approve: true, status: 'approved' }).success).toBe(
      false,
    );
  });
  it('wants a uuid in the params', () => {
    expect(CreditExceptionIdParams.safeParse({ id: ID }).success).toBe(true);
    expect(CreditExceptionIdParams.safeParse({ id: 'nope' }).success).toBe(false);
  });
});

describe('CreditLimitExceededDetail and the error codes', () => {
  it('carries the numbers and the reasons', () => {
    const detail = {
      limit: '20000.00',
      exposure: '14000.00',
      available: '6000.00',
      requested: '6000.01',
      score: 75,
      min_score: 50,
      reasons: ['limit'],
    };
    expect(CreditLimitExceededDetail.safeParse(detail).success).toBe(true);
    expect(CreditLimitExceededDetail.safeParse({ ...detail, reasons: [] }).success).toBe(false);
  });
  it('maps the five codes to their statuses', () => {
    expect(errorCodeHttpStatus.CREDIT_LIMIT_EXCEEDED).toBe(409);
    expect(errorCodeHttpStatus.CREDIT_SCORE_TOO_LOW).toBe(409);
    expect(errorCodeHttpStatus.CREDIT_CUSTOMER_WATCH).toBe(409);
    expect(errorCodeHttpStatus.CREDIT_APPROVAL_INVALID).toBe(409);
    expect(errorCodeHttpStatus.CREDIT_REASON_REQUIRED).toBe(400);
  });
});
