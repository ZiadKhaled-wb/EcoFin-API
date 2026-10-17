import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { CustomerStatus } from './customers.js';
import { InstallmentFrequency } from './settings.js';

/**
 * N04 overdue tracking (D79). Every day, in the shop's time zone, the server records what late
 * contracts need, without ever adding to what a customer owes (docs/ISLAMIC_FINANCE_RULES.md rule
 * 4: no late fee or penalty of any kind): a warning on the first overdue day and every N days
 * after, a ban past the shop's ban days (the customer is blocked; the owner lifts it by hand), a
 * legal referral past the legal days (kept until the owner dismisses it or a legal case is opened
 * from it). An installment is overdue only after its due date plus the policy's grace days; days
 * late count from the due date. No fee field anywhere.
 */

export const OVERDUE_ACTION_KINDS = ['warning', 'ban', 'legal_referral'] as const;
export const OverdueActionKind = z.enum(OVERDUE_ACTION_KINDS);
export type OverdueActionKind = z.infer<typeof OverdueActionKind>;

export const OVERDUE_ACTION_STATUSES = [
  'open',
  'handled',
  'superseded',
  'resolved',
  'dismissed',
  'case_opened',
] as const;
export const OverdueActionStatus = z.enum(OVERDUE_ACTION_STATUSES);
export type OverdueActionStatus = z.infer<typeof OverdueActionStatus>;

/** What the staff did about a warning. `other` needs a note. */
export const WARNING_OUTCOMES = [
  'contacted',
  'promised',
  'no_answer',
  'wrong_number',
  'other',
] as const;
export const WarningOutcome = z.enum(WARNING_OUTCOMES);
export type WarningOutcome = z.infer<typeof WarningOutcome>;

const OverdueContractRef = z.object({
  id: Uuid,
  number: z.string(),
  frequency: InstallmentFrequency,
  branch_id: Uuid,
});
const OverdueCustomerRef = z.object({
  id: Uuid,
  name: z.string(),
  phone: z.string().nullable(),
  /** `blocked` once the overdue check (or the owner) banned the customer. */
  status: CustomerStatus,
});

/** `GET /api/overdue`: filters. Worst first (most days late). */
export const OverdueListQuery = z
  .object({
    q: z.string().trim().min(1).max(100).optional(),
    branch_id: Uuid.optional(),
    /** Only contracts at least this many days late (default 1). */
    min_days: z.coerce.number().int().min(1).max(100000).optional(),
    limit: z.coerce.number().int().min(1).max(100).optional(),
    cursor: z.string().min(1).max(200).optional(),
  })
  .strict();
export type OverdueListQuery = z.infer<typeof OverdueListQuery>;
export type OverdueListQueryInput = z.input<typeof OverdueListQuery>;

export const OverdueContractRow = z.object({
  contract: OverdueContractRef,
  customer: OverdueCustomerRef,
  overdue_amount: Money,
  overdue_lines: z.number().int(),
  max_days_late: z.number().int(),
  oldest_due_date: BusinessDate,
  remaining: Money,
  last_payment_at: IsoTimestamp.nullable(),
  open_warning: z.object({ id: Uuid, business_date: BusinessDate }).nullable(),
  legal_referral: z
    .object({ id: Uuid, status: OverdueActionStatus, business_date: BusinessDate })
    .nullable(),
});
export type OverdueContractRow = z.infer<typeof OverdueContractRow>;

/** Totals for the same filters, with the receivables aging buckets (D03 reuses them). */
export const OverdueTotals = z.object({
  contracts: z.number().int(),
  overdue_amount: Money,
  late_1_30: Money,
  late_31_60: Money,
  late_61_90: Money,
  late_90_plus: Money,
});
export type OverdueTotals = z.infer<typeof OverdueTotals>;

export const OverdueListPage = z.object({
  items: z.array(OverdueContractRow),
  next_cursor: z.string().nullable(),
  totals: OverdueTotals,
});
export type OverdueListPage = z.infer<typeof OverdueListPage>;

/** A warning or a legal referral (the same record shape). */
export const OverdueAction = z.object({
  id: Uuid,
  kind: OverdueActionKind,
  status: OverdueActionStatus,
  /** The shop date the check recorded it. */
  business_date: BusinessDate,
  /** Days late and overdue amount when it was recorded. */
  days_late: z.number().int(),
  overdue_amount: Money,
  contract: OverdueContractRef,
  customer: OverdueCustomerRef,
  /** The contract today (0.00 / null once it caught up). */
  current: z.object({ overdue_amount: Money, max_days_late: z.number().int().nullable() }),
  outcome: WarningOutcome.nullable(),
  /** The warning's note, or the reason a referral was dismissed. */
  note: z.string().nullable(),
  handled_at: IsoTimestamp.nullable(),
  handled_by_name: z.string().nullable(),
  /** L01: the legal case opened from this referral. */
  legal_case_id: Uuid.nullable(),
  created_at: IsoTimestamp,
});
export type OverdueAction = z.infer<typeof OverdueAction>;

export const OverdueActionPage = z.object({
  items: z.array(OverdueAction),
  next_cursor: z.string().nullable(),
});
export type OverdueActionPage = z.infer<typeof OverdueActionPage>;

/** `GET /api/overdue/warnings`: open ones oldest first (default), the others newest first. */
export const OverdueWarningListQuery = z
  .object({
    status: z.enum(['open', 'handled', 'all']).optional(),
    branch_id: Uuid.optional(),
    limit: z.coerce.number().int().min(1).max(100).optional(),
    cursor: z.string().min(1).max(200).optional(),
  })
  .strict();
export type OverdueWarningListQuery = z.infer<typeof OverdueWarningListQuery>;
export type OverdueWarningListQueryInput = z.input<typeof OverdueWarningListQuery>;

/** `GET /api/overdue/legal-referrals`. */
export const LegalReferralListQuery = z
  .object({
    status: z.enum(['open', 'dismissed', 'case_opened', 'all']).optional(),
    branch_id: Uuid.optional(),
    limit: z.coerce.number().int().min(1).max(100).optional(),
    cursor: z.string().min(1).max(200).optional(),
  })
  .strict();
export type LegalReferralListQuery = z.infer<typeof LegalReferralListQuery>;
export type LegalReferralListQueryInput = z.input<typeof LegalReferralListQuery>;

export const OverdueActionIdParams = z.object({ id: Uuid }).strict();
export type OverdueActionIdParams = z.infer<typeof OverdueActionIdParams>;

/** `POST /api/overdue/warnings/:id/handle`. */
export const HandleWarningBody = z
  .object({
    outcome: WarningOutcome,
    note: z.string().trim().max(500).optional(),
  })
  .strict()
  .refine((b) => b.outcome !== 'other' || (b.note?.length ?? 0) >= 3, {
    message: 'A note is required for other',
    path: ['note'],
  });
export type HandleWarningBody = z.infer<typeof HandleWarningBody>;

/** `POST /api/overdue/legal-referrals/:id/dismiss` (owner only). */
export const DismissReferralBody = z.object({ reason: z.string().trim().min(3).max(300) }).strict();
export type DismissReferralBody = z.infer<typeof DismissReferralBody>;

/** `POST /api/overdue/run` (owner only) and the nightly job: what this run recorded. */
export const OverdueRunResult = z.object({
  business_date: BusinessDate,
  warnings_created: z.number().int(),
  warnings_resolved: z.number().int(),
  bans: z.number().int(),
  customers_blocked: z.number().int(),
  legal_referrals: z.number().int(),
});
export type OverdueRunResult = z.infer<typeof OverdueRunResult>;

/** OVERDUE_ACTION_NOT_OPEN: the warning or referral is no longer open. */
export const OverdueActionNotOpenDetail = z.object({ status: OverdueActionStatus });
export type OverdueActionNotOpenDetail = z.infer<typeof OverdueActionNotOpenDetail>;
