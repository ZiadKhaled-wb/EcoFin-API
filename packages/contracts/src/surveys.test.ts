import { describe, expect, it } from 'vitest';
import {
  CreditLatestSurvey,
  SURVEY_CHECKLIST,
  SURVEY_CRITERIA,
  Survey,
  SurveyAnswersBody,
  SurveyCancelBody,
  SurveyChecklistComplete,
  SurveyCreateBody,
  SurveyDecisionBody,
  SurveyListQuery,
  SurveyRequiredDetail,
  SurveyRequirement,
  SurveyRequirementQuery,
  SurveyScoresComplete,
  SurveySubmitBody,
} from './surveys.js';
import { CreditProfile } from './credit.js';
import { errorCodeHttpStatus } from './errors.js';

const ID = 'a0750000-0000-4000-8000-000000000001';
const OTHER = 'a0750000-0000-4000-8000-000000000002';
const AT = '2026-10-15T08:00:00.000Z';
const scores = {
  housing_quality: 8,
  neighbourhood: 7,
  income_stability: 6,
  job_status: 9,
  property_ownership: 5,
  overall_impression: 7,
};
const checklist = Object.fromEntries(SURVEY_CHECKLIST.map((k) => [k, true]));
const gps = { lat: 30.0444, lng: 31.2357, gps_accuracy_m: 12.5, client_captured_at: AT };

const survey = {
  id: ID,
  status: 'submitted',
  visit_type: 'home',
  customer: {
    id: OTHER,
    full_name: 'Ahmed Ali',
    phones: ['01001234567'],
    address: '12 Nile St',
    city: 'Cairo',
  },
  assigned_to: { id: OTHER, full_name: 'Collector' },
  instructions: null,
  due_date: '2026-10-18',
  scores,
  checklist,
  notes: 'Clean flat',
  gps,
  gps_low_accuracy: false,
  survey_score: 70,
  photos_count: 3,
  submitted_at: AT,
  decided_by: null,
  decided_at: null,
  decision_note: null,
  valid_until: null,
  created_by: { id: OTHER, full_name: 'Owner' },
  created_at: AT,
  updated_at: AT,
};

describe('R05 survey contracts', () => {
  it('has six criteria and six checklist items', () => {
    expect(SURVEY_CRITERIA).toHaveLength(6);
    expect(SURVEY_CHECKLIST).toHaveLength(6);
    expect(SurveyScoresComplete.safeParse(scores).success).toBe(true);
    expect(SurveyChecklistComplete.safeParse(checklist).success).toBe(true);
  });

  it('parses a survey and a survey without answers', () => {
    expect(Survey.safeParse(survey).success).toBe(true);
    expect(
      Survey.safeParse({
        ...survey,
        status: 'assigned',
        scores: {},
        checklist: {},
        gps: null,
        survey_score: null,
        submitted_at: null,
        notes: null,
      }).success,
    ).toBe(true);
  });

  it('refuses scores outside 1-10, decimals and unknown criteria', () => {
    for (const bad of [0, 11, 7.5]) {
      expect(SurveyAnswersBody.safeParse({ scores: { job_status: bad } }).success).toBe(false);
    }
    expect(SurveyAnswersBody.safeParse({ scores: { car: 5 } }).success).toBe(false);
    expect(SurveyAnswersBody.safeParse({ checklist: { dog: true } }).success).toBe(false);
    expect(SurveyAnswersBody.safeParse({ checklist: { met_customer: 'yes' } }).success).toBe(false);
  });

  it('a save body takes nulls to remove keys and needs at least one key', () => {
    expect(
      SurveyAnswersBody.safeParse({
        scores: { housing_quality: null },
        checklist: { met_customer: null },
      }).success,
    ).toBe(true);
    expect(SurveyAnswersBody.safeParse({ gps: null }).success).toBe(true);
    expect(SurveyAnswersBody.safeParse({}).success).toBe(false);
    expect(SurveyAnswersBody.safeParse({ status: 'approved' }).success).toBe(false);
  });

  it('a submit body may be empty', () => {
    expect(SurveySubmitBody.safeParse({}).success).toBe(true);
    expect(SurveySubmitBody.safeParse({ scores, checklist, gps }).success).toBe(true);
  });

  it('GPS needs all four values in range', () => {
    expect(SurveyAnswersBody.safeParse({ gps: { lat: 30, lng: 31 } }).success).toBe(false);
    expect(SurveyAnswersBody.safeParse({ gps: { ...gps, lat: 91 } }).success).toBe(false);
    expect(SurveyAnswersBody.safeParse({ gps: { ...gps, lng: -181 } }).success).toBe(false);
    expect(SurveyAnswersBody.safeParse({ gps: { ...gps, gps_accuracy_m: -1 } }).success).toBe(
      false,
    );
    expect(
      SurveyAnswersBody.safeParse({ gps: { ...gps, client_captured_at: 'now' } }).success,
    ).toBe(false);
  });

  it('notes are trimmed and at most 2000', () => {
    expect(SurveyAnswersBody.parse({ notes: '  ok  ' }).notes).toBe('ok');
    expect(SurveyAnswersBody.safeParse({ notes: 'n'.repeat(2001) }).success).toBe(false);
  });

  it('assign: customer and assignee required, instructions trimmed, no tenant keys', () => {
    expect(
      SurveyCreateBody.parse({ customer_id: ID, assigned_to: OTHER, instructions: '  bill ' })
        .instructions,
    ).toBe('bill');
    expect(
      SurveyCreateBody.parse({ customer_id: ID, assigned_to: OTHER, instructions: '' })
        .instructions,
    ).toBeNull();
    expect(SurveyCreateBody.safeParse({ customer_id: ID }).success).toBe(false);
    expect(
      SurveyCreateBody.safeParse({ customer_id: ID, assigned_to: OTHER, visit_type: 'car' })
        .success,
    ).toBe(false);
    expect(
      SurveyCreateBody.safeParse({ customer_id: ID, assigned_to: OTHER, organization_id: ID })
        .success,
    ).toBe(false);
    expect(
      SurveyCreateBody.safeParse({
        customer_id: ID,
        assigned_to: OTHER,
        instructions: 'i'.repeat(501),
      }).success,
    ).toBe(false);
  });

  it('cancel needs a reason of 3-300', () => {
    expect(SurveyCancelBody.safeParse({ reason: 'ok' }).success).toBe(false);
    expect(SurveyCancelBody.safeParse({ reason: 'Moved away' }).success).toBe(true);
    expect(SurveyCancelBody.safeParse({ reason: 'r'.repeat(301) }).success).toBe(false);
  });

  it('a rejection needs a note, an approval does not', () => {
    expect(SurveyDecisionBody.safeParse({ decision: 'approve' }).success).toBe(true);
    expect(SurveyDecisionBody.safeParse({ decision: 'reject' }).success).toBe(false);
    expect(SurveyDecisionBody.safeParse({ decision: 'reject', note: '  no ' }).success).toBe(false);
    expect(
      SurveyDecisionBody.safeParse({ decision: 'reject', note: 'Wrong address' }).success,
    ).toBe(true);
    expect(SurveyDecisionBody.safeParse({ decision: 'maybe' }).success).toBe(false);
  });

  it('list query: the mine flag arrives as text', () => {
    expect(SurveyListQuery.parse({ mine: 'true' }).mine).toBe(true);
    expect(SurveyListQuery.parse({}).mine).toBe(false);
    expect(SurveyListQuery.safeParse({ status: 'done' }).success).toBe(false);
    expect(SurveyListQuery.safeParse({ organization_id: ID }).success).toBe(false);
  });

  it('requirement query and answer', () => {
    expect(SurveyRequirementQuery.safeParse({ financed_amount: '-1.00' }).success).toBe(false);
    expect(SurveyRequirementQuery.safeParse({ financed_amount: '25000.00' }).success).toBe(true);
    expect(
      SurveyRequirement.safeParse({
        policy_id: ID,
        policy_version: 2,
        required_above: '20000.00',
        required: true,
        valid_survey: { id: ID, survey_score: 70, decided_at: AT, valid_until: '2027-04-13' },
        open_survey: null,
        met: true,
      }).success,
    ).toBe(true);
  });

  it('the credit profile carries the latest survey (or null)', () => {
    expect(
      CreditLatestSurvey.safeParse({
        id: ID,
        status: 'approved',
        survey_score: 70,
        decided_at: AT,
        valid_until: '2027-04-13',
      }).success,
    ).toBe(true);
    expect(CreditProfile.shape.latest_survey.safeParse(null).success).toBe(true);
  });

  it('SURVEY_REQUIRED details and the error statuses', () => {
    expect(
      SurveyRequiredDetail.safeParse({
        required_above: '20000.00',
        financed_amount: '25000.00',
        open_survey_id: null,
        open_status: null,
        last_decided_status: 'rejected',
      }).success,
    ).toBe(true);
    expect(errorCodeHttpStatus.SURVEY_NOT_FOUND).toBe(404);
    expect(errorCodeHttpStatus.SURVEY_NOT_ASSIGNEE).toBe(403);
    expect(errorCodeHttpStatus.SURVEY_REQUIRED).toBe(409);
  });
});
