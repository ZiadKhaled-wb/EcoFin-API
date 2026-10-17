import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  dismissReferral,
  handleWarning,
  listOverdueContracts,
  listReferrals,
  listWarnings,
  runCheck,
} from './overdue.service';

const ID = 'a0790000-0000-4000-8000-000000000001';
const ts = '2026-10-17T08:00:00.000Z';
const contract = { id: ID, number: 'MAIN-CT-26-000001', frequency: 'monthly', branch_id: ID };
const customer = { id: ID, name: 'Nadia', phone: '01011112222', status: 'active' };
const action = {
  id: ID,
  kind: 'warning',
  status: 'handled',
  business_date: '2026-10-17',
  days_late: 4,
  overdue_amount: '1000.00',
  contract,
  customer,
  current: { overdue_amount: '1000.00', max_days_late: 4 },
  outcome: 'promised',
  note: 'Thursday',
  handled_at: ts,
  handled_by_name: 'Mona',
  legal_case_id: null,
  created_at: ts,
};
const totals = {
  contracts: 0,
  overdue_amount: '0.00',
  late_1_30: '0.00',
  late_31_60: '0.00',
  late_61_90: '0.00',
  late_90_plus: '0.00',
};

function setup(role = 'BRANCH_MANAGER') {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role,
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  } as RequestContext;
  return { db, ctx };
}

describe('N04 overdue service', () => {
  it('lists overdue contracts with the filters as given and the totals', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], next_cursor: null, totals }, error: null });
    expect(await listOverdueContracts(ctx, { min_days: 30, branch_id: ID })).toEqual({
      items: [],
      next_cursor: null,
      totals,
    });
    expect(db.rpc).toHaveBeenCalledWith('list_overdue_contracts', {
      p_filters: { min_days: 30, branch_id: ID },
    });
  });

  it('lists warnings and legal referrals', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [action], next_cursor: null }, error: null });
    expect((await listWarnings(ctx, { status: 'all' })).items).toHaveLength(1);
    expect(db.rpc).toHaveBeenCalledWith('list_overdue_warnings', { p_filters: { status: 'all' } });
    db.queue({ data: { items: [], next_cursor: null }, error: null });
    await listReferrals(ctx, {});
    expect(db.rpc).toHaveBeenCalledWith('list_legal_referrals', { p_filters: {} });
  });

  it('handles a warning with or without a note', async () => {
    const { db, ctx } = setup();
    db.queue({ data: action, error: null });
    expect((await handleWarning(ctx, ID, { outcome: 'promised', note: 'Thursday' })).status).toBe(
      'handled',
    );
    expect(db.rpc).toHaveBeenCalledWith('handle_overdue_warning', {
      p_id: ID,
      p_outcome: 'promised',
      p_note: 'Thursday',
    });
    db.queue({ data: action, error: null });
    await handleWarning(ctx, ID, { outcome: 'no_answer' });
    expect(db.rpc).toHaveBeenLastCalledWith('handle_overdue_warning', {
      p_id: ID,
      p_outcome: 'no_answer',
    });
  });

  it('maps a warning that is no longer open to OVERDUE_ACTION_NOT_OPEN with its status', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        message: 'OVERDUE_ACTION_NOT_OPEN: handled',
        code: 'P0001',
        details: JSON.stringify({ status: 'handled' }),
        hint: '',
      },
    });
    await expect(handleWarning(ctx, ID, { outcome: 'contacted' })).rejects.toMatchObject({
      code: 'OVERDUE_ACTION_NOT_OPEN',
      statusCode: 409,
    });
  });

  it('dismisses a referral with the reason; another shop’s id is not found', async () => {
    const { db, ctx } = setup('OWNER');
    db.queue({ data: { ...action, kind: 'legal_referral', status: 'dismissed' }, error: null });
    await dismissReferral(ctx, ID, { reason: 'Agreed a payment plan' });
    expect(db.rpc).toHaveBeenCalledWith('dismiss_legal_referral', {
      p_id: ID,
      p_reason: 'Agreed a payment plan',
    });
    db.queue({
      data: null,
      error: { message: 'OVERDUE_ACTION_NOT_FOUND', code: 'P0001', details: '', hint: '' },
    });
    await expect(dismissReferral(ctx, ID, { reason: 'Not ours' })).rejects.toMatchObject({
      code: 'OVERDUE_ACTION_NOT_FOUND',
      statusCode: 404,
    });
  });

  it('runs the check and answers the counts; a late fee answers LATE_FEES_NOT_ALLOWED', async () => {
    const { db, ctx } = setup('OWNER');
    const counts = {
      business_date: '2026-10-17',
      warnings_created: 2,
      warnings_resolved: 0,
      bans: 1,
      customers_blocked: 1,
      legal_referrals: 0,
    };
    db.queue({ data: counts, error: null });
    expect(await runCheck(ctx)).toEqual(counts);
    expect(db.rpc).toHaveBeenCalledWith('run_overdue_check');
    db.queue({
      data: null,
      error: { message: 'LATE_FEES_NOT_ALLOWED', code: 'P0001', details: '', hint: '' },
    });
    await expect(runCheck(ctx)).rejects.toMatchObject({
      code: 'LATE_FEES_NOT_ALLOWED',
      statusCode: 422,
    });
  });
});
