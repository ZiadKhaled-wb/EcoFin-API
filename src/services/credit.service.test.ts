import { describe, it, expect, vi } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { mapDbError } from '../utils/errors';
import { logger } from '../utils/logger';
import {
  cancelCreditException,
  decideCreditException,
  getCreditCheck,
  getCreditException,
  getCreditProfile,
  listCreditExceptions,
  requestCreditException,
  setCreditLimit,
} from './credit.service';

const ID = 'a0730000-0000-4000-8000-000000000001';
const CUSTOMER = 'a0730000-0000-4000-8000-000000000002';
const AT = '2026-10-16T09:00:00.000Z';

const profile = (extra: Record<string, unknown> = {}) => ({
  customer_id: CUSTOMER,
  status: 'active',
  credit_limit: '20000.00',
  suggested_limit: '24000.00',
  exposure: '14000.00',
  available: '6000.00',
  over_limit_by: '0.00',
  score: 75,
  min_score: 50,
  components: [
    { key: 'guarantors', weight: 40, value: 1, points: 40 },
    { key: 'income', weight: 30, value: 1, points: 30 },
    { key: 'residence', weight: 20, value: 0, points: 0 },
    { key: 'identity', weight: 10, value: 0.5, points: 5 },
  ],
  behaviour: {
    due_lines: 0,
    on_time_pct: null,
    max_days_late: null,
    current_overdue_amount: '0.00',
    overdue_lines: 0,
    open_contracts: 0,
    completed_contracts: 0,
  },
  store_credit: '0.00',
  limit_history: [],
  ...extra,
});
const exception = (extra: Record<string, unknown> = {}) => ({
  id: ID,
  status: 'pending',
  customer_id: CUSTOMER,
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
  ...extra,
});

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'CASHIER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('R03 credit service', () => {
  it('reads the profile of a customer through the database function', async () => {
    const { db, ctx } = setup();
    db.queue({ data: profile(), error: null });
    expect(await getCreditProfile(ctx, CUSTOMER)).toMatchObject({
      credit_limit: '20000.00',
      available: '6000.00',
      score: 75,
    });
    expect(db.rpc).toHaveBeenCalledWith('get_customer_credit_profile', { p_customer_id: CUSTOMER });
  });

  it('refuses an answer that is not the contract shape', async () => {
    const { db, ctx } = setup();
    db.queue({ data: profile({ score: 120 }), error: null });
    await expect(getCreditProfile(ctx, CUSTOMER)).rejects.toThrow();
  });

  it('sets the limit with the reason when there is one and without when there is none', async () => {
    const { db, ctx } = setup();
    db.queue({ data: profile(), error: null });
    await setCreditLimit(ctx, CUSTOMER, { credit_limit: '20000.00', reason: 'Good payer' });
    expect(db.rpc).toHaveBeenLastCalledWith('set_customer_credit_limit', {
      p_customer_id: CUSTOMER,
      p_limit: '20000.00',
      p_reason: 'Good payer',
    });
    db.queue({ data: profile({ credit_limit: '10000.00' }), error: null });
    await setCreditLimit(ctx, CUSTOMER, { credit_limit: '10000.00' });
    expect(db.rpc).toHaveBeenLastCalledWith('set_customer_credit_limit', {
      p_customer_id: CUSTOMER,
      p_limit: '10000.00',
    });
  });

  it('previews the check for a financed amount', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: {
        allowed: false,
        reasons: ['limit'],
        needs_approval: true,
        limit: '20000.00',
        exposure: '14000.00',
        available: '6000.00',
        score: 75,
        min_score: 50,
        pending_approval_id: null,
        approved_approval_id: null,
      },
      error: null,
    });
    expect(await getCreditCheck(ctx, CUSTOMER, { financed_amount: '8000.00' })).toMatchObject({
      allowed: false,
      needs_approval: true,
      reasons: ['limit'],
    });
    expect(db.rpc).toHaveBeenCalledWith('get_customer_credit_check', {
      p_customer_id: CUSTOMER,
      p_financed_amount: '8000.00',
    });
  });

  it('requests an exception with the amount and the reason', async () => {
    const { db, ctx } = setup();
    db.queue({ data: exception(), error: null });
    expect(
      await requestCreditException(ctx, CUSTOMER, {
        financed_amount: '8000.00',
        reason: 'New fridge',
      }),
    ).toMatchObject({ status: 'pending', mine: true, reasons: ['limit'] });
    expect(db.rpc).toHaveBeenCalledWith('request_credit_exception', {
      p_customer_id: CUSTOMER,
      p_financed_amount: '8000.00',
      p_reason: 'New fridge',
    });
  });

  it('lists by status and reads one', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [exception()] }, error: null });
    expect((await listCreditExceptions(ctx, { status: 'all' })).items).toHaveLength(1);
    expect(db.rpc).toHaveBeenLastCalledWith('list_credit_exceptions', { p_status: 'all' });
    db.queue({ data: exception(), error: null });
    expect(await getCreditException(ctx, ID)).toMatchObject({ id: ID });
    expect(db.rpc).toHaveBeenLastCalledWith('get_credit_exception', { p_id: ID });
  });

  it('decides with the note when there is one and cancels by id', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: exception({ status: 'rejected', decided_at: AT, decided_by_name: 'Manager' }),
      error: null,
    });
    await decideCreditException(ctx, ID, { approve: false, note: 'Too much' });
    expect(db.rpc).toHaveBeenLastCalledWith('decide_credit_exception', {
      p_approval_id: ID,
      p_approve: false,
      p_note: 'Too much',
    });
    db.queue({
      data: exception({ status: 'approved', decided_at: AT, expires_at: AT }),
      error: null,
    });
    await decideCreditException(ctx, ID, { approve: true });
    expect(db.rpc).toHaveBeenLastCalledWith('decide_credit_exception', {
      p_approval_id: ID,
      p_approve: true,
    });
    db.queue({ data: exception({ status: 'cancelled' }), error: null });
    expect(await cancelCreditException(ctx, ID)).toMatchObject({ status: 'cancelled' });
    expect(db.rpc).toHaveBeenLastCalledWith('cancel_credit_exception', { p_approval_id: ID });
  });

  it('maps a database error to its code and logs only the message and the Postgres code', async () => {
    const { db, ctx } = setup();
    const log = vi.spyOn(logger, 'error').mockImplementation(() => undefined);
    db.queue({
      data: null,
      error: { message: 'CREDIT_REASON_REQUIRED', code: 'P0001', details: 'secret detail' },
    });
    const err = await setCreditLimit(ctx, CUSTOMER, { credit_limit: '30000.00' }).catch(
      (e: unknown) => e,
    );
    expect(err).toMatchObject({ code: 'CREDIT_REASON_REQUIRED', statusCode: 400 });
    expect(log).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(log.mock.calls)).not.toContain('secret detail');
    log.mockRestore();
  });

  it.each(['CREDIT_LIMIT_EXCEEDED', 'CREDIT_SCORE_TOO_LOW', 'CREDIT_CUSTOMER_WATCH'] as const)(
    '%s carries the numbers of the check',
    (code) => {
      const detail = {
        limit: '20000.00',
        exposure: '14000.00',
        available: '6000.00',
        requested: '6000.01',
        score: 75,
        min_score: 50,
        reasons: ['limit'],
      };
      expect(mapDbError({ message: code, details: JSON.stringify(detail) })).toMatchObject({
        code,
        statusCode: 409,
        details: detail,
      });
    },
  );

  it('drops a detail that is not the contract shape', () => {
    const err = mapDbError({
      message: 'CREDIT_LIMIT_EXCEEDED',
      details: JSON.stringify({ national_id: '29001010100015' }),
    });
    expect(err).toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED' });
    expect(err?.details).toBeUndefined();
  });

  it.each([
    ['CREDIT_APPROVAL_INVALID', 409],
    ['CREDIT_REASON_REQUIRED', 400],
    ['CUSTOMER_NOT_FOUND', 404],
    ['CUSTOMER_BLOCKED', 409],
    ['APPROVAL_NOT_FOUND', 404],
    ['APPROVAL_NOT_PENDING', 409],
    ['APPROVAL_NOT_NEEDED', 400],
    ['APPROVAL_NOTE_REQUIRED', 400],
    ['APPROVAL_SELF', 403],
    ['PERMISSION_DENIED', 403],
  ] as const)('maps %s', (code, status) => {
    expect(mapDbError({ message: code + ': private detail' })).toMatchObject({
      code,
      statusCode: status,
    });
  });
});
