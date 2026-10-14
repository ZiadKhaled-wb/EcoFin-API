import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { FiscalStatus } from './eta.js';

/**
 * T03 ETA submission monitor and corrections (EC-91). Every receipt is in one situation; the
 * screen and the API use these names. A problem is a blocked, send_failed or rejected receipt.
 */

export const FiscalSituation = z.enum([
  'waiting',
  'accepted',
  'cancelled',
  'blocked',
  'send_failed',
  'rejected',
]);
export type FiscalSituation = z.infer<typeof FiscalSituation>;

/** The list filter: one situation, or every receipt that needs a person. */
export const FiscalSituationFilter = z.union([FiscalSituation, z.literal('problem')]);
export type FiscalSituationFilter = z.infer<typeof FiscalSituationFilter>;

/** `due_soon`: under 4 hours left. `overdue`: it needs a Late Submission Request in the ETA portal. */
export const FiscalDeadlineState = z.enum(['ok', 'due_soon', 'overdue']);
export type FiscalDeadlineState = z.infer<typeof FiscalDeadlineState>;

/** The one primary action of a receipt. */
export const FiscalAction = z.enum(['retry', 'retry_now', 'correct', 'check_now', 'assign_device']);
export type FiscalAction = z.infer<typeof FiscalAction>;

// GET /api/fiscal
export const FiscalListQuery = z
  .object({
    branch_id: Uuid.optional(),
    from: BusinessDate.optional(),
    to: BusinessDate.optional(),
    situation: FiscalSituationFilter.optional(),
    q: z.string().trim().max(100).optional(),
    limit: z.coerce.number().int().min(1).max(100).default(50),
    offset: z.coerce.number().int().min(0).default(0),
  })
  .strict()
  .refine((q) => !q.from || !q.to || q.from <= q.to, { message: 'Invalid date range' });
export type FiscalListQuery = z.infer<typeof FiscalListQuery>;

export const FiscalListItem = z.object({
  id: Uuid,
  /** The sale (or, for a return receipt, the sale it returns): the link to its detail page. */
  sale_id: Uuid,
  sale_number: z.string(),
  issued_at: IsoTimestamp,
  branch_id: Uuid,
  branch_name: z.string(),
  device_id: Uuid.nullable(),
  device_name: z.string().nullable(),
  total: Money.nullable(),
  status: FiscalStatus,
  situation: FiscalSituation,
  /** The first 120 characters of the last error. */
  short_error: z.string().nullable(),
  deadline_at: IsoTimestamp.nullable(),
  deadline_state: FiscalDeadlineState,
});
export type FiscalListItem = z.infer<typeof FiscalListItem>;

export const FiscalList = z.object({
  items: z.array(FiscalListItem),
  total_count: z.number().int().min(0),
});
export type FiscalList = z.infer<typeof FiscalList>;

// GET /api/fiscal/summary
export const FiscalAlertSummary = z.object({
  blocked: z.number().int().min(0),
  send_failed: z.number().int().min(0),
  rejected: z.number().int().min(0),
  due_soon: z.number().int().min(0),
  overdue: z.number().int().min(0),
  accepted_today: z.number().int().min(0),
});
export type FiscalAlertSummary = z.infer<typeof FiscalAlertSummary>;

// GET /api/fiscal/day-summary (for the day close, K04)
export const FiscalDaySummaryQuery = z.object({ branch_id: Uuid, date: BusinessDate }).strict();
export type FiscalDaySummaryQuery = z.infer<typeof FiscalDaySummaryQuery>;

export const FiscalDaySummary = z.object({
  branch_id: Uuid,
  business_date: BusinessDate,
  total: z.number().int().min(0),
  waiting: z.number().int().min(0),
  accepted: z.number().int().min(0),
  cancelled: z.number().int().min(0),
  blocked: z.number().int().min(0),
  send_failed: z.number().int().min(0),
  rejected: z.number().int().min(0),
  /** Nothing is waiting or in trouble (a void's cancelled receipt does not count against it). */
  all_accepted: z.boolean(),
});
export type FiscalDaySummary = z.infer<typeof FiscalDaySummary>;

/** Where a fix is made. */
export const FiscalFix = z.enum([
  'assign_device',
  'device',
  'product',
  'eta_settings',
  'shop_profile',
  'branch',
  'customer',
  'support',
]);
export type FiscalFix = z.infer<typeof FiscalFix>;

export const FiscalSellerField = z.enum([
  'rin',
  'activity_code',
  'branch_code',
  'governorate',
  'city',
  'street',
  'building_number',
]);
export type FiscalSellerField = z.infer<typeof FiscalSellerField>;

/** The ETA's refusal, parsed from the stored error. */
export const FiscalEtaError = z.object({
  message: z.string(),
  property_path: z.string().nullable(),
  details: z.array(z.string()),
  /** The last correction found the data unchanged. */
  nothing_changed: z.boolean(),
});
export type FiscalEtaError = z.infer<typeof FiscalEtaError>;

/**
 * One thing that needs fixing, from the data as it is now. `fixable: false` means the sale can't be
 * changed (BUYER_MISSING): it needs support. Never a national ID.
 */
export const FiscalProblem = z.object({
  code: z.enum([
    'NO_DEVICE',
    'ITEM_CODE',
    'SELLER_DATA',
    'BUYER_ID',
    'BUYER_MISSING',
    'ETA_REJECTED',
  ]),
  fixable: z.boolean(),
  fix: FiscalFix.nullable(),
  /** NO_DEVICE: `missing` (assign one) or `not_active` (register the POS with the ETA). */
  reason: z.string().optional(),
  device_id: Uuid.optional(),
  branch_id: Uuid.optional(),
  customer_id: Uuid.optional(),
  products: z.array(z.object({ product_id: Uuid, name: z.string(), sku: z.string() })).optional(),
  fields: z.array(z.object({ field: FiscalSellerField, fix: FiscalFix })).optional(),
  eta_error: FiscalEtaError.optional(),
});
export type FiscalProblem = z.infer<typeof FiscalProblem>;

export const FiscalDiagnosis = z.object({
  situation: FiscalSituation,
  action: FiscalAction.nullable(),
  /** The action can run now. */
  ready: z.boolean(),
  correction_queued: z.boolean(),
  deadline_at: IsoTimestamp.nullable(),
  deadline_state: FiscalDeadlineState,
  problems: z.array(FiscalProblem),
});
export type FiscalDiagnosis = z.infer<typeof FiscalDiagnosis>;

export const FiscalEvent = z.object({
  id: z.number().int(),
  at: IsoTimestamp,
  old_status: FiscalStatus.nullable(),
  new_status: FiscalStatus,
  eta_uuid: z.string().nullable(),
  message: z.string().nullable(),
  actor_employee_id: Uuid.nullable(),
});
export type FiscalEvent = z.infer<typeof FiscalEvent>;

// GET /api/fiscal/:id
export const FiscalDetails = z.object({
  row: z.object({
    id: Uuid,
    doc_type: z.string(),
    status: FiscalStatus,
    situation: FiscalSituation,
    sale_number: z.string(),
    issued_at: IsoTimestamp,
    total: Money.nullable(),
    branch_id: Uuid,
    branch_name: z.string(),
    device_id: Uuid.nullable(),
    device_name: z.string().nullable(),
    environment: z.string(),
    eta_uuid: z.string().nullable(),
    previous_uuid: z.string().nullable(),
    reference_old_uuid: z.string().nullable(),
    eta_long_id: z.string().nullable(),
    eta_submission_uuid: z.string().nullable(),
    attempts: z.number().int(),
    next_retry_at: IsoTimestamp.nullable(),
    last_error: z.string().nullable(),
    submitted_at: IsoTimestamp.nullable(),
    accepted_at: IsoTimestamp.nullable(),
    created_at: IsoTimestamp,
    deadline_at: IsoTimestamp.nullable(),
    deadline_state: FiscalDeadlineState,
  }),
  situation: FiscalSituation,
  diagnosis: FiscalDiagnosis,
  events: z.array(FiscalEvent),
  sale: z.object({ id: Uuid, number: z.string() }),
});
export type FiscalDetails = z.infer<typeof FiscalDetails>;

// POST /api/fiscal/:id/assign-device
export const FiscalAssignDeviceBody = z.object({ device_id: Uuid }).strict();
export type FiscalAssignDeviceBody = z.infer<typeof FiscalAssignDeviceBody>;

// POST /api/fiscal/:id/correct and /check-now (202)
export const FiscalQueued = z.object({ id: Uuid, status: FiscalStatus, queued: z.literal(true) });
export type FiscalQueued = z.infer<typeof FiscalQueued>;

// POST /api/fiscal/retry-many
export const FISCAL_RETRY_MANY_MAX = 200;
export const FiscalRetryManyBody = z
  .object({ ids: z.array(Uuid).min(1).max(FISCAL_RETRY_MANY_MAX) })
  .strict();
export type FiscalRetryManyBody = z.infer<typeof FiscalRetryManyBody>;

export const FiscalRetryManyResult = z.object({
  done: z.number().int().min(0),
  skipped: z.array(z.object({ id: Uuid, reason: z.string() })),
});
export type FiscalRetryManyResult = z.infer<typeof FiscalRetryManyResult>;
