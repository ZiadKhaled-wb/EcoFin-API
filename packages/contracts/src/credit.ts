import { z } from 'zod';
import { IsoTimestamp, Money, Uuid } from './common.js';
import { CustomerStatus } from './customers.js';

/**
 * R03 credit profile and limit (D72).
 *
 * A customer has an explicit credit limit (`customers.credit_limit`, set by a user with
 * `credit.approve`). Exposure = the unpaid principal of the customer's open contracts (active and
 * rescheduled); available = limit - exposure, never shown below 0 (`over_limit_by` carries the
 * excess). `suggested_limit` (monthly income x the shop's multiple, rounded down to the pound) is
 * shown and prefilled but never used by the check.
 *
 * One server function decides whether an installment sale of a financed amount is allowed (N02
 * calls it in its transaction; a commit-time trigger on `contracts` is the safety net). Three
 * reasons need an exception: the amount is above the available credit (`limit`), the score is
 * below the shop's minimum (`score`), the customer is on `watch`. A blocked or archived customer
 * is never overridable (`CUSTOMER_BLOCKED`). An exception is an approval on the spot (like the
 * S03 discount approvals): requested for a customer and amount, decided by `credit.approve`
 * (the requester can't, except the owner), valid for 24 hours after the decision, for ONE contract.
 */

/** The limit and every amount in this module: up to 99 999 999.99. */
export const CREDIT_AMOUNT_MAX = '99999999.99';
/** How long an approved exception can still be used. */
export const CREDIT_EXCEPTION_VALID_HOURS = 24;

const AMOUNT = /^\d{1,8}(\.\d{1,2})?$/;
const POSITIVE_AMOUNT = /^(?!0+(\.0{1,2})?$)\d{1,8}(\.\d{1,2})?$/;

export const CreditReason = z.enum(['limit', 'score', 'watch']);
export type CreditReason = z.infer<typeof CreditReason>;

export const CreditScoreKey = z.enum(['guarantors', 'income', 'residence', 'identity']);
export type CreditScoreKey = z.infer<typeof CreditScoreKey>;

/** `value` is 0..1; `points` = `weight` x `value`. The score is the sum of the points, rounded half up. */
export const CreditScoreComponent = z.object({
  key: CreditScoreKey,
  weight: z.number().min(0).max(100),
  value: z.number().min(0).max(1),
  points: z.number().min(0).max(100),
});
export type CreditScoreComponent = z.infer<typeof CreditScoreComponent>;

/** Over the customer's current schedule lines that are due; null where nothing is due yet. */
export const CreditBehaviour = z.object({
  due_lines: z.number().int().min(0),
  /** Whole percent of the due lines that were fully paid by their due date. */
  on_time_pct: z.number().int().min(0).max(100).nullable(),
  max_days_late: z.number().int().min(0).nullable(),
  current_overdue_amount: Money,
  overdue_lines: z.number().int().min(0),
  open_contracts: z.number().int().min(0),
  completed_contracts: z.number().int().min(0),
});
export type CreditBehaviour = z.infer<typeof CreditBehaviour>;

export const CreditLimitChange = z.object({
  at: IsoTimestamp,
  by_name: z.string().nullable(),
  from: Money,
  to: Money,
  reason: z.string().nullable(),
});
export type CreditLimitChange = z.infer<typeof CreditLimitChange>;

/** `GET /api/customers/:id/credit`. Read only: the score is computed, nothing is stored. */
export const CreditProfile = z.object({
  customer_id: Uuid,
  status: CustomerStatus,
  credit_limit: Money,
  suggested_limit: Money.nullable(),
  exposure: Money,
  available: Money,
  over_limit_by: Money,
  score: z.number().int().min(0).max(100),
  min_score: z.number().int().min(0).max(100),
  components: z.array(CreditScoreComponent).length(4),
  behaviour: CreditBehaviour,
  store_credit: Money,
  /** The last 10 changes, newest first. */
  limit_history: z.array(CreditLimitChange).max(10),
});
export type CreditProfile = z.infer<typeof CreditProfile>;

/**
 * `PUT /api/customers/:id/credit-limit` (`credit.approve`). A reason (3-300) is required when the
 * limit goes up (`CREDIT_REASON_REQUIRED`); the same value again changes nothing.
 */
export const CreditLimitBody = z
  .object({
    credit_limit: Money.regex(AMOUNT, 'A limit from 0 to 99 999 999.99'),
    reason: z.string().trim().max(300).optional(),
  })
  .strict();
export type CreditLimitBody = z.infer<typeof CreditLimitBody>;

/** `GET /api/customers/:id/credit-check?financed_amount=` (cash price - down payment). */
export const CreditCheckQuery = z
  .object({
    financed_amount: Money.regex(POSITIVE_AMOUNT, 'An amount above 0 up to 99 999 999.99'),
  })
  .strict();
export type CreditCheckQuery = z.infer<typeof CreditCheckQuery>;

/**
 * Would an installment sale of this amount pass now? Answers instead of raising for the credit
 * reasons. `allowed` = no reason, or a usable approved exception exists; `needs_approval` = there
 * are reasons and no usable exception. A customer who is not found, blocked or archived is an error.
 */
export const CreditCheck = z.object({
  allowed: z.boolean(),
  reasons: z.array(CreditReason),
  needs_approval: z.boolean(),
  limit: Money,
  exposure: Money,
  available: Money,
  score: z.number().int().min(0).max(100),
  min_score: z.number().int().min(0).max(100),
  /** The newest pending request of this customer that covers the amount. */
  pending_approval_id: Uuid.nullable(),
  /** The newest approved, unused, unexpired exception that covers the amount. */
  approved_approval_id: Uuid.nullable(),
});
export type CreditCheck = z.infer<typeof CreditCheck>;

/** `POST /api/customers/:id/credit-exceptions` (`sale.create` or `credit.approve`). */
export const CreditExceptionRequestBody = z
  .object({
    financed_amount: Money.regex(POSITIVE_AMOUNT, 'An amount above 0 up to 99 999 999.99'),
    /** Required: 3-300 characters (`CREDIT_REASON_REQUIRED`). */
    reason: z.string().trim().max(300),
  })
  .strict();
export type CreditExceptionRequestBody = z.infer<typeof CreditExceptionRequestBody>;

/** `POST /api/credit-exceptions/:id/decide` (`credit.approve`). Rejecting needs a note. */
export const CreditExceptionDecideBody = z
  .object({ approve: z.boolean(), note: z.string().trim().max(500).optional() })
  .strict();
export type CreditExceptionDecideBody = z.infer<typeof CreditExceptionDecideBody>;

export const CreditExceptionStatus = z.enum(['pending', 'approved', 'rejected', 'cancelled']);
export type CreditExceptionStatus = z.infer<typeof CreditExceptionStatus>;

/** What the server knew when the exception was requested. */
export const CreditExceptionSnapshot = z.object({
  limit: Money,
  exposure: Money,
  available: Money,
  score: z.number().int().min(0).max(100),
  min_score: z.number().int().min(0).max(100),
});
export type CreditExceptionSnapshot = z.infer<typeof CreditExceptionSnapshot>;

export const CreditException = z.object({
  id: Uuid,
  status: CreditExceptionStatus,
  customer_id: Uuid,
  customer_name: z.string().nullable(),
  financed_amount: Money,
  reasons: z.array(CreditReason),
  reason: z.string().nullable(),
  snapshot: CreditExceptionSnapshot,
  requested_by_name: z.string().nullable(),
  requested_at: IsoTimestamp,
  /** The caller is the requester (only they can cancel it). */
  mine: z.boolean(),
  decided_by_name: z.string().nullable(),
  decided_at: IsoTimestamp.nullable(),
  decision_note: z.string().nullable(),
  /** Approved only: 24 hours after the decision. */
  expires_at: IsoTimestamp.nullable(),
  /** True once a contract has used it. */
  used: z.boolean(),
});
export type CreditException = z.infer<typeof CreditException>;

export const CreditExceptionList = z.object({ items: z.array(CreditException) });
export type CreditExceptionList = z.infer<typeof CreditExceptionList>;

/** `GET /api/credit-exceptions?status=` (pending first, then newest; at most 100). */
export const CreditExceptionListQuery = z
  .object({
    status: z.enum(['pending', 'approved', 'rejected', 'cancelled', 'all']).default('pending'),
  })
  .strict();
export type CreditExceptionListQuery = z.infer<typeof CreditExceptionListQuery>;

export const CreditExceptionIdParams = z.object({ id: Uuid }).strict();
export type CreditExceptionIdParams = z.infer<typeof CreditExceptionIdParams>;

/**
 * Details of `CREDIT_LIMIT_EXCEEDED`, `CREDIT_SCORE_TOO_LOW` and `CREDIT_CUSTOMER_WATCH`: the
 * numbers the check used and every reason it found (`limit` first when it is among them).
 */
export const CreditLimitExceededDetail = z.object({
  limit: Money,
  exposure: Money,
  available: Money,
  requested: Money,
  score: z.number().int().min(0).max(100),
  min_score: z.number().int().min(0).max(100),
  reasons: z.array(CreditReason).min(1),
});
export type CreditLimitExceededDetail = z.infer<typeof CreditLimitExceededDetail>;
