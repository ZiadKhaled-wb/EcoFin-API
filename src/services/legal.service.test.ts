import { describe, it, expect } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import {
  addHearing,
  addNote,
  getCase,
  listCases,
  listLawyers,
  openCase,
  setStatus,
  updateCase,
  updateHearing,
} from './legal.service';

const ID = 'a1010000-0000-4000-8000-000000000001';
const ts = '2026-10-24T08:00:00.000Z';
const row = {
  id: ID,
  number: 'MAIN-LC-26-000001',
  case_number: null,
  court: null,
  case_type: null,
  status: 'preparing',
  opened_on: '2026-10-24',
  next_hearing_date: null,
  claim_amount: '11000.00',
  remaining: '11000.00',
  contract: { id: ID, number: 'MAIN-CT-26-000001', branch_id: ID },
  customer: { id: ID, name: 'Nadia', phone: '01011112222', status: 'blocked' },
  lawyer: null,
};
const detail = {
  ...row,
  guarantors: [],
  hearings: [],
  notes: [{ id: ID, note: 'First', created_at: ts, created_by_name: 'Owner' }],
  amounts: {
    claim_amount: '11000.00',
    total_payable: '14000.00',
    paid_before_case: '1000.00',
    paid_since_opened: '0.00',
    remaining: '11000.00',
  },
  collections_since_opened: [],
  referral: null,
  outcome_kind: null,
  outcome: null,
  closed_at: null,
  created_by_name: 'Owner',
};

function setup(role = 'OWNER') {
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

describe('L01 legal service', () => {
  it('lists cases with the filters as given', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { rows: [row], next_cursor: null }, error: null });
    const out = await listCases(ctx, { status: 'all', q: 'Nadia' });
    expect(out.rows).toHaveLength(1);
    expect(db.rpc).toHaveBeenCalledWith('list_legal_cases', {
      p_filters: { status: 'all', q: 'Nadia' },
    });
  });

  it('reads a case; a shape the contract does not know is a server error, not a leak', async () => {
    const { db, ctx } = setup();
    db.queue({ data: detail, error: null });
    expect((await getCase(ctx, ID)).amounts.paid_before_case).toBe('1000.00');
    expect(db.rpc).toHaveBeenCalledWith('get_legal_case', { p_id: ID });
    db.queue({ data: { ...detail, claim_amount: 11000 }, error: null });
    await expect(getCase(ctx, ID)).rejects.toThrow();
  });

  it('opens a case with the body and the idempotency key', async () => {
    const { db, ctx } = setup();
    db.queue({ data: detail, error: null });
    await openCase(ctx, { contract_id: ID, claim_amount: '11000.00' }, 'key-12345678');
    expect(db.rpc).toHaveBeenCalledWith('open_legal_case', {
      p_body: { contract_id: ID, claim_amount: '11000.00' },
      p_idempotency_key: 'key-12345678',
    });
  });

  it('sends each write to its function and answers the case detail', async () => {
    const { db, ctx } = setup();
    for (let i = 0; i < 5; i += 1) db.queue({ data: detail, error: null });
    await updateCase(ctx, ID, { court: 'Cairo' });
    expect(db.rpc).toHaveBeenLastCalledWith('update_legal_case', {
      p_id: ID,
      p_body: { court: 'Cairo' },
    });
    await setStatus(ctx, ID, { status: 'closed', outcome_kind: 'paid' });
    expect(db.rpc).toHaveBeenLastCalledWith('set_legal_case_status', {
      p_id: ID,
      p_body: { status: 'closed', outcome_kind: 'paid' },
    });
    await addHearing(ctx, ID, { hearing_date: '2026-11-01' });
    expect(db.rpc).toHaveBeenLastCalledWith('add_legal_hearing', {
      p_case_id: ID,
      p_body: { hearing_date: '2026-11-01' },
    });
    await updateHearing(ctx, ID, ID, { outcome: 'Adjourned' });
    expect(db.rpc).toHaveBeenLastCalledWith('update_legal_hearing', {
      p_case_id: ID,
      p_hearing_id: ID,
      p_body: { outcome: 'Adjourned' },
    });
    await addNote(ctx, ID, { note: 'Called the guarantor' });
    expect(db.rpc).toHaveBeenLastCalledWith('add_legal_case_note', {
      p_case_id: ID,
      p_body: { note: 'Called the guarantor' },
    });
  });

  it('lists the lawyers', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: { items: [{ id: ID, full_name: 'Lawyer', phone: null, open_cases: 2 }] },
      error: null,
    });
    expect((await listLawyers(ctx)).items[0]?.open_cases).toBe(2);
    expect(db.rpc).toHaveBeenCalledWith('list_lawyers');
  });

  it.each([
    ['LEGAL_CASE_NOT_FOUND', 404],
    ['HEARING_NOT_FOUND', 404],
    ['LEGAL_CASE_CLOSED', 409],
    ['LEGAL_CASE_FILED', 409],
    ['LEGAL_CONTRACT_NOT_DEFAULTED', 422],
    ['LAWYER_INVALID', 422],
  ] as const)('maps %s to %s', async (code, status) => {
    const { db, ctx } = setup();
    db.queue({ data: null, error: { message: code, code: 'P0001', details: '', hint: '' } });
    await expect(getCase(ctx, ID)).rejects.toMatchObject({ code, statusCode: status });
  });

  it('maps the already open case to 409 with its id, and the claim limit to 422 with the remaining', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        message: 'LEGAL_CASE_ALREADY_OPEN',
        code: 'P0001',
        details: JSON.stringify({ legal_case_id: ID }),
        hint: '',
      },
    });
    await expect(openCase(ctx, { contract_id: ID }, 'key-12345678')).rejects.toMatchObject({
      code: 'LEGAL_CASE_ALREADY_OPEN',
      statusCode: 409,
      details: { legal_case_id: ID },
    });
    db.queue({
      data: null,
      error: {
        message: 'LEGAL_CLAIM_TOO_HIGH',
        code: 'P0001',
        details: JSON.stringify({ remaining: '10500.00' }),
        hint: '',
      },
    });
    await expect(updateCase(ctx, ID, { claim_amount: '99999.00' })).rejects.toMatchObject({
      code: 'LEGAL_CLAIM_TOO_HIGH',
      statusCode: 422,
      details: { remaining: '10500.00' },
    });
  });

  it('maps a refused status move with where it came from and where it went', async () => {
    const { db, ctx } = setup();
    db.queue({
      data: null,
      error: {
        message: 'LEGAL_STATUS_INVALID',
        code: 'P0001',
        details: JSON.stringify({ from: 'preparing', to: 'judgment' }),
        hint: '',
      },
    });
    await expect(setStatus(ctx, ID, { status: 'judgment' })).rejects.toMatchObject({
      code: 'LEGAL_STATUS_INVALID',
      statusCode: 409,
      details: { from: 'preparing', to: 'judgment' },
    });
  });
});
