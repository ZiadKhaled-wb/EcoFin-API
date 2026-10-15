import { describe, it, expect, vi } from 'vitest';
import { createSupabaseMock } from '../test/supabase-mock';
import type { DbClient } from '../utils/supabase';
import type { RequestContext } from '../middleware/requestContext';
import { logger } from '../utils/logger';
import {
  assignSurvey,
  cancelSurvey,
  decideSurvey,
  getSurvey,
  getSurveyRequirement,
  listCustomerSurveys,
  listSurveys,
  reassignSurvey,
  saveSurvey,
  submitSurvey,
} from './surveys.service';

const ID = 'a0750000-0000-4000-8000-000000000001';
const CUSTOMER = 'a0750000-0000-4000-8000-000000000002';
const EMP = 'a0750000-0000-4000-8000-000000000003';
const AT = '2026-10-15T08:00:00.000Z';
const row = (extra: Record<string, unknown> = {}) => ({
  id: ID,
  status: 'assigned',
  visit_type: 'home',
  customer: {
    id: CUSTOMER,
    full_name: 'Ahmed Ali',
    phones: ['01001234567'],
    address: null,
    city: null,
  },
  assigned_to: { id: EMP, full_name: 'Collector' },
  instructions: null,
  due_date: null,
  scores: {},
  checklist: {},
  notes: null,
  gps: null,
  gps_low_accuracy: false,
  survey_score: null,
  photos_count: 0,
  submitted_at: null,
  decided_by: null,
  decided_at: null,
  decision_note: null,
  valid_until: null,
  created_by: { id: EMP, full_name: 'Owner' },
  created_at: AT,
  updated_at: AT,
  ...extra,
});

function setup() {
  const db = createSupabaseMock();
  const ctx: RequestContext = {
    userId: 'u',
    employeeId: 'e',
    orgId: 'org',
    role: 'COLLECTOR',
    defaultBranchId: null,
    branchIds: [],
    mustChangePassword: false,
    db: db as unknown as DbClient,
  };
  return { db, ctx };
}

describe('R05 survey service', () => {
  it('lists with the filters and paging turned into the function arguments', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [row()], total: 51 }, error: null });
    const list = await listSurveys(ctx, {
      page: 2,
      pageSize: 50,
      status: 'submitted',
      customer_id: CUSTOMER,
      mine: true,
    });
    expect(list).toMatchObject({ page: 2, pageSize: 50, total: 51 });
    expect(db.rpc).toHaveBeenCalledWith('list_field_surveys', {
      p_status: 'submitted',
      p_customer_id: CUSTOMER,
      p_mine: true,
      p_limit: 50,
      p_offset: 50,
    });
  });

  it('leaves out the filters that were not sent', async () => {
    const { db, ctx } = setup();
    db.queue({ data: { items: [], total: 0 }, error: null });
    await listSurveys(ctx, { page: 1, pageSize: 20, mine: false });
    expect(db.rpc).toHaveBeenCalledWith('list_field_surveys', {
      p_mine: false,
      p_limit: 20,
      p_offset: 0,
    });
  });

  it('gets, assigns, reassigns and cancels through the database functions', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row(), error: null });
    await getSurvey(ctx, ID);
    expect(db.rpc).toHaveBeenLastCalledWith('get_field_survey', { p_id: ID });

    db.queue({ data: row(), error: null });
    await assignSurvey(ctx, { customer_id: CUSTOMER, assigned_to: EMP, visit_type: 'work' });
    expect(db.rpc).toHaveBeenLastCalledWith('assign_field_survey', {
      p_body: { customer_id: CUSTOMER, assigned_to: EMP, visit_type: 'work' },
    });

    db.queue({ data: row(), error: null });
    await reassignSurvey(ctx, ID, { assigned_to: EMP });
    expect(db.rpc).toHaveBeenLastCalledWith('reassign_field_survey', {
      p_id: ID,
      p_assigned_to: EMP,
    });

    db.queue({ data: row({ status: 'cancelled', decision_note: 'Moved' }), error: null });
    const cancelled = await cancelSurvey(ctx, ID, { reason: 'Moved' });
    expect(cancelled.status).toBe('cancelled');
    expect(db.rpc).toHaveBeenLastCalledWith('cancel_field_survey', { p_id: ID, p_reason: 'Moved' });
  });

  it('save and submit pass the body as it is (nulls remove keys)', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row({ scores: { neighbourhood: 7 } }), error: null });
    await saveSurvey(ctx, ID, { scores: { housing_quality: null, neighbourhood: 7 } });
    expect(db.rpc).toHaveBeenLastCalledWith('save_field_survey', {
      p_id: ID,
      p_body: { scores: { housing_quality: null, neighbourhood: 7 } },
    });

    db.queue({ data: row({ status: 'submitted', survey_score: 70 }), error: null });
    const submitted = await submitSurvey(ctx, ID, {});
    expect(submitted.survey_score).toBe(70);
    expect(db.rpc).toHaveBeenLastCalledWith('submit_field_survey', { p_id: ID, p_body: {} });
  });

  it('decide sends the note only when there is one', async () => {
    const { db, ctx } = setup();
    db.queue({ data: row({ status: 'approved' }), error: null });
    await decideSurvey(ctx, ID, { decision: 'approve' });
    expect(db.rpc).toHaveBeenLastCalledWith('decide_field_survey', {
      p_id: ID,
      p_decision: 'approve',
    });
    db.queue({ data: row({ status: 'rejected', decision_note: 'Wrong address' }), error: null });
    await decideSurvey(ctx, ID, { decision: 'reject', note: 'Wrong address' });
    expect(db.rpc).toHaveBeenLastCalledWith('decide_field_survey', {
      p_id: ID,
      p_decision: 'reject',
      p_note: 'Wrong address',
    });
  });

  it('customer surveys and the requirement', async () => {
    const { db, ctx } = setup();
    db.queue({ data: [row()], error: null });
    expect(await listCustomerSurveys(ctx, CUSTOMER)).toHaveLength(1);
    expect(db.rpc).toHaveBeenLastCalledWith('list_customer_surveys', { p_customer_id: CUSTOMER });
    db.queue({
      data: {
        policy_id: null,
        policy_version: null,
        required_above: null,
        required: false,
        valid_survey: null,
        open_survey: null,
        met: true,
      },
      error: null,
    });
    expect((await getSurveyRequirement(ctx, CUSTOMER, { financed_amount: '1000.00' })).met).toBe(
      true,
    );
    expect(db.rpc).toHaveBeenLastCalledWith('get_survey_requirement', {
      p_customer_id: CUSTOMER,
      p_financed_amount: '1000.00',
    });
  });

  it('maps the database codes and their details; logs no body', async () => {
    const { db, ctx } = setup();
    const spy = vi.spyOn(logger, 'error').mockImplementation(() => undefined);
    db.queue({
      data: null,
      error: {
        message: 'SURVEY_ALREADY_OPEN',
        code: 'P0001',
        details: JSON.stringify({ survey_id: ID, status: 'assigned' }),
      },
    });
    await expect(
      assignSurvey(ctx, { customer_id: CUSTOMER, assigned_to: EMP }),
    ).rejects.toMatchObject({
      statusCode: 409,
      code: 'SURVEY_ALREADY_OPEN',
      details: { survey_id: ID },
    });
    db.queue({ data: null, error: { message: 'SURVEY_NOT_ASSIGNEE', code: 'P0001' } });
    await expect(saveSurvey(ctx, ID, { notes: 'Secret note' })).rejects.toMatchObject({
      statusCode: 403,
      code: 'SURVEY_NOT_ASSIGNEE',
    });
    db.queue({ data: null, error: { message: 'SURVEY_NOT_FOUND', code: 'P0001' } });
    await expect(getSurvey(ctx, ID)).rejects.toMatchObject({ statusCode: 404 });
    expect(JSON.stringify(spy.mock.calls)).not.toContain('Secret note');
    spy.mockRestore();
  });

  it('an unknown database error is a 500 with no detail', async () => {
    const { db, ctx } = setup();
    vi.spyOn(logger, 'error').mockImplementation(() => undefined);
    db.queue({ data: null, error: { message: 'boom', code: 'XX000' } });
    await expect(getSurvey(ctx, ID)).rejects.toMatchObject({ statusCode: 500 });
  });
});
