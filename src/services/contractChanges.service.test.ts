import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  getHistory,
  getSettlementQuote,
  listChanges,
  previewReschedule,
  reschedule,
  writeOff,
} from './contractChanges.service';

const ID = 'a0800000-0000-4000-8000-000000000001';
const ts = '2026-10-18T08:00:00.000Z';
const change = {
  id: ID,
  kind: 'reschedule',
  contract_id: ID,
  old_version: 1,
  new_version: 2,
  amount: '10500.00',
  principal_amount: '8750.00',
  profit_amount: '1750.00',
  profit_waived: '0.00',
  reason: 'Lost his job',
  business_date: '2026-10-18',
  created_at: ts,
  created_by: { id: ID, name: 'Mona' },
  approved_by: null,
  payment_id: null,
};
const quote = {
  contract_id: ID,
  number: 'MAIN-CT-26-000001',
  status: 'active',
  remaining: '11000.00',
  principal_left: '9166.67',
  profit_left: '1833.33',
  future_profit: '1666.66',
  suggested_waiver: '833.33',
  max_waiver: '1666.66',
  policy_rule: { early_settlement_rule: 'percent_of_future_profit', early_settlement_pct: '50.00' },
};

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'BRANCH_MANAGER',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('N05 contract changes service', () => {
  it('reads the settlement quote', async () => {
    const { db, ctx } = setup();
    db.queue({ data: quote, error: null });
    expect((await getSettlementQuote(ctx, ID)).max_waiver).toBe('1666.66');
    expect(db.rpc).toHaveBeenCalledWith('get_settlement_quote', { p_contract_id: ID });
  });

  it('previews and writes a reschedule with the key', async () => {
    const { db, ctx } = setup();
    const plan = {
      installments_count: 3,
      frequency: 'monthly' as const,
      first_due_date: '2026-11-18',
    };
    db.queue({
      data: {
        remaining: '300.00',
        principal_left: '250.00',
        profit_left: '50.00',
        lines: [],
        violations: [],
      },
      error: null,
    });
    await previewReschedule(ctx, ID, plan);
    expect(db.rpc).toHaveBeenCalledWith('preview_reschedule', { p_contract_id: ID, p_body: plan });
    db.queue({ data: null, error: { message: 'boom', code: 'XX000', details: '', hint: '' } });
    await expect(
      reschedule(
        ctx,
        ID,
        { ...plan, reason: 'Lost his job', expected_remaining: '300.00' },
        'key-12345',
      ),
    ).rejects.toMatchObject({ code: 'INTERNAL' });
    expect(db.rpc).toHaveBeenLastCalledWith('reschedule_contract', {
      p_contract_id: ID,
      p_body: { ...plan, reason: 'Lost his job', expected_remaining: '300.00' },
      p_idempotency_key: 'key-12345',
    });
  });

  it('maps WAIVER_TOO_HIGH with the max waiver', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        message: 'WAIVER_TOO_HIGH: at most 1666.66',
        code: 'P0001',
        details: JSON.stringify({ max_waiver: '1666.66' }),
        hint: '',
      },
    });
    await expect(
      writeOff(ctx, ID, { reason: 'Gone abroad', expected_remaining: '11000.00' }, 'key-12345'),
    ).rejects.toMatchObject({ code: 'WAIVER_TOO_HIGH', details: { max_waiver: '1666.66' } });
  });

  it('reads a contract history and the shop list', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { changes: [change], versions: [] }, error: null });
    expect((await getHistory(ctx, ID)).changes).toHaveLength(1);
    expect(db.rpc).toHaveBeenCalledWith('list_contract_changes_for', { p_contract_id: ID });
    db.queue({ data: { items: [], next_cursor: null, totals: [] }, error: null });
    await listChanges(ctx, { kind: 'write_off', limit: 10 });
    expect(db.rpc).toHaveBeenLastCalledWith('list_contract_changes', {
      p_filters: { kind: 'write_off', limit: 10 },
    });
  });
});
