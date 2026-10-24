import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { CustomerStatus } from './customers.js';

/**
 * L01 + N09 legal module (D92). The owner turns a defaulted contract into a legal case (from
 * N04's legal referral, or straight from the contract). The case carries the court details, the
 * assigned lawyer, its status, hearings, notes and documents. While a case is open the contract
 * and the customer account show a "legal" flag (N09: computed from the case, never stored). A
 * LAWYER employee sees only the cases assigned to them. Money received through the legal process is
 * an ordinary collection (N03 / N06); the case only reads it. Nothing here ever changes what a
 * customer owes: no fee, no cost, no charge (docs/ISLAMIC_FINANCE_RULES.md rule 4). All money is a
 * string. Descriptions say profit, never interest.
 */

export const LEGAL_CASE_STATUSES = [
  'preparing',
  'filed',
  'in_court',
  'judgment',
  'closed',
] as const;
export const LegalCaseStatus = z.enum(LEGAL_CASE_STATUSES);
export type LegalCaseStatus = z.infer<typeof LegalCaseStatus>;

/** How a case ended. `other` needs a note. */
export const LEGAL_OUTCOME_KINDS = [
  'paid',
  'settled_out_of_court',
  'judgment_enforced',
  'withdrawn',
  'dismissed_by_court',
  'other',
] as const;
export const LegalOutcomeKind = z.enum(LEGAL_OUTCOME_KINDS);
export type LegalOutcomeKind = z.infer<typeof LegalOutcomeKind>;

/**
 * The moves a case may make: preparing -> filed -> in_court -> judgment, judgment -> in_court (an
 * appeal), and any open status -> closed. A closed case never reopens (the owner opens a new one).
 */
export const LEGAL_NEXT_STATUSES: Record<LegalCaseStatus, readonly LegalCaseStatus[]> = {
  preparing: ['filed', 'closed'],
  filed: ['in_court', 'closed'],
  in_court: ['judgment', 'closed'],
  judgment: ['in_court', 'closed'],
  closed: [],
};
export const legalNextStatuses = (status: LegalCaseStatus): readonly LegalCaseStatus[] =>
  LEGAL_NEXT_STATUSES[status];

/** N09: the contract's open case, on the contract and on the customer account's contract rows. */
export const ContractLegalFlag = z.object({
  id: Uuid,
  number: z.string(),
  status: LegalCaseStatus,
  opened_on: BusinessDate,
});
export type ContractLegalFlag = z.infer<typeof ContractLegalFlag>;

/** The same flag on a row of the overdue list (no opening date). */
export const OverdueLegalFlag = ContractLegalFlag.omit({ opened_on: true });
export type OverdueLegalFlag = z.infer<typeof OverdueLegalFlag>;

const OptionalText = (max: number) => z.string().trim().max(max);
const PositiveMoney = Money.refine((v) => !/^0+(\.0+)?$/.test(v) && !v.startsWith('-'), {
  message: 'Must be above 0',
});

/** A guarantor of the contract (the same figures as `Contract.guarantors`). */
export const LegalCaseGuarantor = z.object({
  id: Uuid,
  name: z.string(),
  relation: z.string().nullable(),
});
export type LegalCaseGuarantor = z.infer<typeof LegalCaseGuarantor>;

/** One row of `GET /api/legal/cases`. */
export const LegalCaseRow = z.object({
  id: Uuid,
  /** Our own number (LC prefix). */
  number: z.string(),
  /** The court's number. */
  case_number: z.string().nullable(),
  court: z.string().nullable(),
  case_type: z.string().nullable(),
  status: LegalCaseStatus,
  /** The shop date the case was opened. */
  opened_on: BusinessDate,
  /** The earliest hearing from today on that has no outcome yet, computed live. */
  next_hearing_date: BusinessDate.nullable(),
  /** What the shop claims: the contract's remaining by default, never more. */
  claim_amount: Money,
  /** What the contract still owes now. */
  remaining: Money,
  contract: z.object({ id: Uuid, number: z.string(), branch_id: Uuid }),
  customer: z.object({
    id: Uuid,
    name: z.string(),
    phone: z.string().nullable(),
    status: CustomerStatus,
  }),
  lawyer: z.object({ id: Uuid, name: z.string() }).nullable(),
});
export type LegalCaseRow = z.infer<typeof LegalCaseRow>;

/** `GET /api/legal/cases`: open cases with the soonest hearing first, then the closed ones. */
export const LegalCaseListQuery = z
  .object({
    status: z.enum(['open', 'closed', 'all']).optional(),
    /** The owner only; a lawyer always gets their own cases. */
    lawyer_id: Uuid.optional(),
    /** Matches the case number, the court's number, the contract number, the customer's name or phone. */
    q: z.string().trim().min(1).max(100).optional(),
    limit: z.coerce.number().int().min(1).max(100).optional(),
    cursor: z.string().min(1).max(200).optional(),
  })
  .strict();
export type LegalCaseListQuery = z.infer<typeof LegalCaseListQuery>;
export type LegalCaseListQueryInput = z.input<typeof LegalCaseListQuery>;

export const LegalCaseListResponse = z.object({
  rows: z.array(LegalCaseRow),
  next_cursor: z.string().nullable(),
});
export type LegalCaseListResponse = z.infer<typeof LegalCaseListResponse>;

export const LegalHearing = z.object({
  id: Uuid,
  hearing_date: BusinessDate,
  outcome: z.string().nullable(),
  notes: z.string().nullable(),
  created_at: IsoTimestamp,
});
export type LegalHearing = z.infer<typeof LegalHearing>;

/** Notes are append-only: no edit, no delete. */
export const LegalCaseNote = z.object({
  id: Uuid,
  note: z.string(),
  created_at: IsoTimestamp,
  created_by_name: z.string().nullable(),
});
export type LegalCaseNote = z.infer<typeof LegalCaseNote>;

/**
 * What the case shows about the money (read only): the claim, the contract's total payable, what
 * was paid before and since the day the case was opened (effective collections by business date),
 * and what the contract still owes now.
 */
export const LegalCaseAmounts = z.object({
  claim_amount: Money,
  total_payable: Money,
  paid_before_case: Money,
  paid_since_opened: Money,
  remaining: Money,
});
export type LegalCaseAmounts = z.infer<typeof LegalCaseAmounts>;

/** A collection (N03 / N06 receipt) taken on the contract since the case was opened. */
export const LegalCaseCollection = z.object({
  receipt_id: Uuid,
  number: z.string(),
  date: BusinessDate,
  /** The amount that went to this contract. */
  amount: Money,
  taken_by: z.string().nullable(),
});
export type LegalCaseCollection = z.infer<typeof LegalCaseCollection>;

/** `GET /api/legal/cases/:id`, and the answer of every write. */
export const LegalCaseDetail = LegalCaseRow.extend({
  guarantors: z.array(LegalCaseGuarantor),
  /** All of them, by date. */
  hearings: z.array(LegalHearing),
  /** Newest first. */
  notes: z.array(LegalCaseNote),
  amounts: LegalCaseAmounts,
  /** Up to 50, newest first. */
  collections_since_opened: z.array(LegalCaseCollection),
  /** The N04 legal referral this case was opened from. */
  referral: z
    .object({ id: Uuid, business_date: BusinessDate, days_late: z.number().int() })
    .nullable(),
  outcome_kind: LegalOutcomeKind.nullable(),
  outcome: z.string().nullable(),
  closed_at: IsoTimestamp.nullable(),
  created_by_name: z.string().nullable(),
});
export type LegalCaseDetail = z.infer<typeof LegalCaseDetail>;

export const LegalCaseIdParams = z.object({ id: Uuid }).strict();
export type LegalCaseIdParams = z.infer<typeof LegalCaseIdParams>;
export const LegalHearingParams = z.object({ id: Uuid, hearingId: Uuid }).strict();
export type LegalHearingParams = z.infer<typeof LegalHearingParams>;

/** `POST /api/legal/cases` (owner only; header Idempotency-Key). */
export const OpenLegalCaseBody = z
  .object({
    contract_id: Uuid,
    lawyer_employee_id: Uuid.optional(),
    court: OptionalText(200).optional(),
    case_type: OptionalText(100).optional(),
    /** The court's number. */
    case_number: OptionalText(100).optional(),
    /** Above 0 and not above what the contract still owes; court costs are never part of it. */
    claim_amount: PositiveMoney.optional(),
    /** Becomes the first case note. */
    note: z.string().trim().min(1).max(2000).optional(),
  })
  .strict();
export type OpenLegalCaseBody = z.infer<typeof OpenLegalCaseBody>;

/** `PATCH /api/legal/cases/:id`. The lawyer is changed by the owner only, the claim only while preparing. */
export const UpdateLegalCaseBody = z
  .object({
    court: OptionalText(200).nullable().optional(),
    case_type: OptionalText(100).nullable().optional(),
    case_number: OptionalText(100).nullable().optional(),
    claim_amount: PositiveMoney.optional(),
    lawyer_employee_id: Uuid.nullable().optional(),
  })
  .strict()
  .refine((b) => Object.values(b).some((v) => v !== undefined), { message: 'Nothing to change' });
export type UpdateLegalCaseBody = z.infer<typeof UpdateLegalCaseBody>;

/** `POST /api/legal/cases/:id/status`. Closing needs an outcome kind (and a note for `other`). */
export const SetLegalCaseStatusBody = z
  .object({
    status: LegalCaseStatus,
    outcome_kind: LegalOutcomeKind.optional(),
    outcome: z.string().trim().min(1).max(1000).optional(),
  })
  .strict()
  .superRefine((b, ctx) => {
    if (b.status !== 'closed') {
      if (b.outcome_kind !== undefined || b.outcome !== undefined) {
        ctx.addIssue({ code: 'custom', path: ['outcome_kind'], message: 'Only when closing' });
      }
      return;
    }
    if (b.outcome_kind === undefined) {
      ctx.addIssue({
        code: 'custom',
        path: ['outcome_kind'],
        message: 'An outcome kind is required',
      });
    } else if (b.outcome_kind === 'other' && b.outcome === undefined) {
      ctx.addIssue({ code: 'custom', path: ['outcome'], message: 'A note is required for other' });
    }
  });
export type SetLegalCaseStatusBody = z.infer<typeof SetLegalCaseStatusBody>;

/** `POST /api/legal/cases/:id/hearings`. A past date is allowed (recording history). */
export const AddHearingBody = z
  .object({ hearing_date: BusinessDate, notes: z.string().trim().min(1).max(2000).optional() })
  .strict();
export type AddHearingBody = z.infer<typeof AddHearingBody>;

/** `PATCH /api/legal/cases/:id/hearings/:hearingId`. */
export const UpdateHearingBody = z
  .object({
    hearing_date: BusinessDate.optional(),
    outcome: OptionalText(500).nullable().optional(),
    notes: OptionalText(2000).nullable().optional(),
  })
  .strict()
  .refine((b) => Object.values(b).some((v) => v !== undefined), { message: 'Nothing to change' });
export type UpdateHearingBody = z.infer<typeof UpdateHearingBody>;

/** `POST /api/legal/cases/:id/notes`. */
export const AddCaseNoteBody = z.object({ note: z.string().trim().min(1).max(2000) }).strict();
export type AddCaseNoteBody = z.infer<typeof AddCaseNoteBody>;

/** `GET /api/legal/lawyers` (owner only): the shop's active LAWYER employees. */
export const Lawyer = z.object({
  id: Uuid,
  full_name: z.string(),
  phone: z.string().nullable(),
  open_cases: z.number().int().min(0),
});
export type Lawyer = z.infer<typeof Lawyer>;

export const LawyerListResponse = z.object({ items: z.array(Lawyer) });
export type LawyerListResponse = z.infer<typeof LawyerListResponse>;

/** LEGAL_CASE_ALREADY_OPEN: the contract's open case. */
export const LegalCaseAlreadyOpenDetail = z.object({ legal_case_id: Uuid });
export type LegalCaseAlreadyOpenDetail = z.infer<typeof LegalCaseAlreadyOpenDetail>;

/** LEGAL_CLAIM_TOO_HIGH: what the contract still owes. */
export const LegalClaimTooHighDetail = z.object({ remaining: Money });
export type LegalClaimTooHighDetail = z.infer<typeof LegalClaimTooHighDetail>;

/** LEGAL_STATUS_INVALID: the move that was refused. */
export const LegalStatusInvalidDetail = z.object({ from: LegalCaseStatus, to: LegalCaseStatus });
export type LegalStatusInvalidDetail = z.infer<typeof LegalStatusInvalidDetail>;
