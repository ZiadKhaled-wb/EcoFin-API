import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, PaginationQuery, Uuid, paginated } from './common.js';

/**
 * R05 field surveys (D75).
 *
 * A manager (`survey.assign`) assigns a home or work visit to an employee who has `survey.submit`;
 * the assignee fills the six criteria (1-10), the yes/no checklist, notes and the GPS fix, uploads
 * photos (F14 files, purpose `survey_photo`, entity `field_survey`, private) and submits; a
 * `survey.decide` user approves or rejects. Flow: assigned -> submitted -> approved | rejected;
 * cancelled from assigned or submitted. The latest approved survey of the last 180 days fills the
 * residence part of the credit score (R03) and, above the policy's `survey_required_above`, allows
 * an installment contract.
 */
export const SURVEY_CRITERIA = [
  'housing_quality',
  'neighbourhood',
  'income_stability',
  'job_status',
  'property_ownership',
  'overall_impression',
] as const;
export const SurveyCriterion = z.enum(SURVEY_CRITERIA);
export type SurveyCriterion = z.infer<typeof SurveyCriterion>;

export const SURVEY_CHECKLIST = [
  'met_customer',
  'address_matches',
  'id_original_seen',
  'neighbours_confirm',
  'utility_bill_seen',
  'workplace_confirmed',
] as const;
export const SurveyChecklistItem = z.enum(SURVEY_CHECKLIST);
export type SurveyChecklistItem = z.infer<typeof SurveyChecklistItem>;

export const SURVEY_STATUSES = [
  'assigned',
  'submitted',
  'approved',
  'rejected',
  'cancelled',
] as const;
export const SurveyStatus = z.enum(SURVEY_STATUSES);
export type SurveyStatus = z.infer<typeof SurveyStatus>;

export const SurveyVisitType = z.enum(['home', 'work']);
export type SurveyVisitType = z.infer<typeof SurveyVisitType>;

export const SURVEY_MAX_PHOTOS = 10;
export const SURVEY_VALID_DAYS = 180;
/** A fix less accurate than this (metres) is flagged to the reviewer, never refused. */
export const SURVEY_LOW_ACCURACY_M = 100;

const Score = z.number().int().min(1).max(10);

/** Saved answers: any criteria, each 1-10. In a save body a criterion sent as `null` is removed. */
export const SurveyScores = z
  .object(
    Object.fromEntries(SURVEY_CRITERIA.map((k) => [k, Score.optional()])) as Record<
      SurveyCriterion,
      z.ZodOptional<typeof Score>
    >,
  )
  .strict();
export type SurveyScores = z.infer<typeof SurveyScores>;
export const SurveyScoresComplete = z
  .object(
    Object.fromEntries(SURVEY_CRITERIA.map((k) => [k, Score])) as Record<
      SurveyCriterion,
      typeof Score
    >,
  )
  .strict();
export type SurveyScoresComplete = z.infer<typeof SurveyScoresComplete>;

export const SurveyChecklist = z
  .object(
    Object.fromEntries(SURVEY_CHECKLIST.map((k) => [k, z.boolean().optional()])) as Record<
      SurveyChecklistItem,
      z.ZodOptional<z.ZodBoolean>
    >,
  )
  .strict();
export type SurveyChecklist = z.infer<typeof SurveyChecklist>;
export const SurveyChecklistComplete = z
  .object(
    Object.fromEntries(SURVEY_CHECKLIST.map((k) => [k, z.boolean()])) as Record<
      SurveyChecklistItem,
      z.ZodBoolean
    >,
  )
  .strict();
export type SurveyChecklistComplete = z.infer<typeof SurveyChecklistComplete>;

/** The phone's GPS fix: all four together. */
export const SurveyGps = z
  .object({
    lat: z.number().min(-90).max(90),
    lng: z.number().min(-180).max(180),
    gps_accuracy_m: z.number().min(0).max(999999.99),
    client_captured_at: IsoTimestamp,
  })
  .strict();
export type SurveyGps = z.infer<typeof SurveyGps>;

const Person = z.object({ id: Uuid, full_name: z.string() });

export const Survey = z.object({
  id: Uuid,
  status: SurveyStatus,
  visit_type: SurveyVisitType,
  customer: z.object({
    id: Uuid,
    full_name: z.string(),
    phones: z.array(z.string()),
    address: z.string().nullable(),
    city: z.string().nullable(),
  }),
  assigned_to: Person,
  instructions: z.string().nullable(),
  due_date: BusinessDate.nullable(),
  scores: SurveyScores,
  checklist: SurveyChecklist,
  notes: z.string().nullable(),
  gps: SurveyGps.nullable(),
  /** `gps_accuracy_m` above {@link SURVEY_LOW_ACCURACY_M}. */
  gps_low_accuracy: z.boolean(),
  /** round(average of the criteria x 10), written on submit. */
  survey_score: z.number().int().min(0).max(100).nullable(),
  photos_count: z.number().int().min(0),
  submitted_at: IsoTimestamp.nullable(),
  decided_by: Person.nullable(),
  decided_at: IsoTimestamp.nullable(),
  /** The decider's note, or the cancel reason. */
  decision_note: z.string().nullable(),
  /** Approved only: the last day the survey counts. */
  valid_until: BusinessDate.nullable(),
  created_by: Person.nullable(),
  created_at: IsoTimestamp,
  updated_at: IsoTimestamp,
});
export type Survey = z.infer<typeof Survey>;
export const SurveyArray = z.array(Survey);
export type SurveyArray = z.infer<typeof SurveyArray>;

/** Query strings arrive as text: 'true' / 'false' for the flag. */
const QueryFlag = z.union([z.boolean(), z.enum(['true', 'false']).transform((v) => v === 'true')]);

/**
 * Newest first; without a status filter the submitted ones (the review queue) come first. A caller
 * with `survey.submit` but neither `survey.assign` nor `survey.decide` sees only their own surveys;
 * `mine` limits anyone to their own.
 */
export const SurveyListQuery = PaginationQuery.extend({
  status: SurveyStatus.optional(),
  customer_id: Uuid.optional(),
  assigned_to: Uuid.optional(),
  mine: QueryFlag.default(false),
}).strict();
export type SurveyListQuery = z.infer<typeof SurveyListQuery>;

export const SurveyList = paginated(Survey);
export type SurveyList = z.infer<typeof SurveyList>;

export const SurveyIdParams = z.object({ id: Uuid }).strict();
export type SurveyIdParams = z.infer<typeof SurveyIdParams>;

const instructions = z
  .string()
  .trim()
  .max(500)
  .nullable()
  .transform((v) => (v === '' ? null : v));

export const SurveyCreateBody = z
  .object({
    customer_id: Uuid,
    assigned_to: Uuid,
    visit_type: SurveyVisitType.optional(),
    /** Not before today (shop calendar). */
    due_date: BusinessDate.nullable().optional(),
    instructions: instructions.optional(),
  })
  .strict();
export type SurveyCreateBody = z.infer<typeof SurveyCreateBody>;
export type SurveyCreateInput = z.input<typeof SurveyCreateBody>;

export const SurveyReassignBody = z.object({ assigned_to: Uuid }).strict();
export type SurveyReassignBody = z.infer<typeof SurveyReassignBody>;

export const SurveyCancelBody = z.object({ reason: z.string().trim().min(3).max(300) }).strict();
export type SurveyCancelBody = z.infer<typeof SurveyCancelBody>;

/** In a save body a criterion or item sent as `null` is removed; `gps: null` clears the fix. */
const answerFields = {
  visit_type: SurveyVisitType.optional(),
  scores: z
    .object(
      Object.fromEntries(SURVEY_CRITERIA.map((k) => [k, Score.nullable().optional()])) as Record<
        SurveyCriterion,
        z.ZodOptional<z.ZodNullable<typeof Score>>
      >,
    )
    .strict()
    .optional(),
  checklist: z
    .object(
      Object.fromEntries(
        SURVEY_CHECKLIST.map((k) => [k, z.boolean().nullable().optional()]),
      ) as Record<SurveyChecklistItem, z.ZodOptional<z.ZodNullable<z.ZodBoolean>>>,
    )
    .strict()
    .optional(),
  notes: z.string().trim().max(2000).nullable().optional(),
  gps: SurveyGps.nullable().optional(),
};

/** `PATCH /api/surveys/:id`: the assignee saves part of the answers (at least one key). */
export const SurveyAnswersBody = z
  .object(answerFields)
  .strict()
  .refine((b) => Object.keys(b).length > 0, { message: 'Nothing to save' });
export type SurveyAnswersBody = z.infer<typeof SurveyAnswersBody>;
export type SurveyAnswersInput = z.input<typeof SurveyAnswersBody>;

/**
 * `POST /api/surveys/:id/submit`: the same keys, merged into what was saved (an empty body submits
 * what was saved). Then every criterion, every checklist item, the GPS fix and at least one photo
 * are required.
 */
export const SurveySubmitBody = z.object(answerFields).strict();
export type SurveySubmitBody = z.infer<typeof SurveySubmitBody>;
export type SurveySubmitInput = z.input<typeof SurveySubmitBody>;

/** A rejection needs a note (3-500); an approval may have one. */
export const SurveyDecisionBody = z
  .object({
    decision: z.enum(['approve', 'reject']),
    note: z.string().trim().max(500).optional(),
  })
  .strict()
  .refine((b) => b.decision === 'approve' || (b.note ?? '').length >= 3, {
    message: 'A rejection needs a note',
    path: ['note'],
  });
export type SurveyDecisionBody = z.infer<typeof SurveyDecisionBody>;

/** `GET /api/customers/:id/survey-requirement?financed_amount=` (cash price - down payment). */
export const SurveyRequirementQuery = z
  .object({ financed_amount: Money.refine((v) => !v.startsWith('-'), { message: 'Not negative' }) })
  .strict();
export type SurveyRequirementQuery = z.infer<typeof SurveyRequirementQuery>;

/** Against the shop's current policy version; the policy fields are null for a shop without one. */
export const SurveyRequirement = z.object({
  policy_id: Uuid.nullable(),
  policy_version: z.number().int().min(1).nullable(),
  required_above: Money.nullable(),
  required: z.boolean(),
  valid_survey: z
    .object({
      id: Uuid,
      survey_score: z.number().int().min(0).max(100).nullable(),
      decided_at: IsoTimestamp,
      valid_until: BusinessDate,
    })
    .nullable(),
  open_survey: z.object({ id: Uuid, status: SurveyStatus }).nullable(),
  met: z.boolean(),
});
export type SurveyRequirement = z.infer<typeof SurveyRequirement>;

/** The newest survey of a customer, whatever its status (on the credit profile). */
export const CreditLatestSurvey = z.object({
  id: Uuid,
  status: SurveyStatus,
  survey_score: z.number().int().min(0).max(100).nullable(),
  decided_at: IsoTimestamp.nullable(),
  valid_until: BusinessDate.nullable(),
});
export type CreditLatestSurvey = z.infer<typeof CreditLatestSurvey>;

/** Details of `SURVEY_ALREADY_OPEN`: the customer's open survey. */
export const SurveyAlreadyOpenDetail = z.object({ survey_id: Uuid, status: SurveyStatus });
export type SurveyAlreadyOpenDetail = z.infer<typeof SurveyAlreadyOpenDetail>;

/** Details of `SURVEY_ASSIGNEE_INVALID`. */
export const SurveyAssigneeInvalidDetail = z.object({ employee_id: Uuid.nullable() });
export type SurveyAssigneeInvalidDetail = z.infer<typeof SurveyAssigneeInvalidDetail>;

/** Details of `SURVEY_REQUIRED` (raised by the contract check, N02). */
export const SurveyRequiredDetail = z.object({
  required_above: Money.nullable(),
  financed_amount: Money,
  open_survey_id: Uuid.nullable(),
  open_status: SurveyStatus.nullable(),
  last_decided_status: z.enum(['approved', 'rejected']).nullable(),
});
export type SurveyRequiredDetail = z.infer<typeof SurveyRequiredDetail>;
