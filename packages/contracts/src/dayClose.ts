import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';

/**
 * K04 day close and reconciliation (D84). At the end of a business day a manager closes it per
 * branch: the server answers the day's numbers and a list of issues, each with a link to its cause;
 * the close stores them as a snapshot and the database then refuses any new entry dated that day
 * for that branch (DAY_CLOSED). The owner can reopen a day with a reason. A nightly job runs the
 * same checks and never closes a day. Every money value is a decimal string from the server; the
 * client never adds money up.
 * Words: day close (إقفال اليوم), profit (ربح) for the collections split; never interest.
 */

export const DAY_CLOSE_STATUSES = ['open', 'closed', 'reopened'] as const;
export const DayCloseStatus = z.enum(DAY_CLOSE_STATUSES);
export type DayCloseStatus = z.infer<typeof DayCloseStatus>;

export const DAY_CLOSE_ISSUE_SEVERITIES = ['blocking', 'warning', 'info'] as const;
export const DayCloseIssueSeverity = z.enum(DAY_CLOSE_ISSUE_SEVERITIES);
export type DayCloseIssueSeverity = z.infer<typeof DayCloseIssueSeverity>;

export const DAY_CLOSE_ISSUE_CODES = [
  /** blocking: a shift of the branch opened on or before the day is still open. */
  'SHIFT_OPEN',
  /** warning: a cached balance (cash or stock) does not equal the sum of its ledger. */
  'LEDGER_MISMATCH',
  /** warning: a document of the day and its cash movements disagree, or a movement has no document. */
  'DOCUMENT_WITHOUT_LEDGER',
  /** warning: some of the day's receipts are not accepted by ETA yet. */
  'ETA_NOT_ACCEPTED',
  /** warning (nightly check only): a closed day's stored numbers differ from its ledgers now. */
  'DAY_DRIFT',
  /** info: a shift closed with a difference. */
  'SHIFT_DIFFERENCE',
  /** info: a collector wallet settled with a shortage. */
  'WALLET_SHORTAGE',
  /** info: earlier days of the branch with activity are not closed. */
  'EARLIER_DAY_OPEN',
] as const;
export const DayCloseIssueCode = z.enum(DAY_CLOSE_ISSUE_CODES);
export type DayCloseIssueCode = z.infer<typeof DayCloseIssueCode>;

/** Where an issue's link goes in the client. `eta_monitor` and `day_list` carry the branch id. */
export const DAY_CLOSE_LINK_KINDS = [
  'shift',
  'cash_account',
  'product',
  'sale',
  'payment',
  'sales_return',
  'expense',
  'supplier_payment',
  'purchase_return',
  'cash_transfer',
  'eta_monitor',
  'day_list',
  'day_close',
] as const;
export const DayCloseLinkKind = z.enum(DAY_CLOSE_LINK_KINDS);
export type DayCloseLinkKind = z.infer<typeof DayCloseLinkKind>;

export const DayCloseIssue = z.object({
  code: DayCloseIssueCode,
  severity: DayCloseIssueSeverity,
  /** Values for the message (numbers, names, amounts as strings); the client words it. */
  params: z.record(z.string(), z.unknown()),
  link: z.object({ kind: DayCloseLinkKind, id: Uuid }).nullable(),
});
export type DayCloseIssue = z.infer<typeof DayCloseIssue>;

export const DayCloseByMethod = z.object({
  cash: Money,
  bank_transfer: Money,
  store_credit: Money,
});
export type DayCloseByMethod = z.infer<typeof DayCloseByMethod>;

const CountTotal = z.object({ count: z.number().int().nonnegative(), total: Money });

export const DayCloseCashAccount = z.object({
  account: z.object({
    id: Uuid,
    name: z.string(),
    kind: z.enum(['safe', 'bank', 'drawer', 'collector_wallet']),
    /** A shop-wide bank: only this branch's movements of the day, no opening or closing. */
    shop_wide: z.boolean(),
  }),
  opening: Money.nullable(),
  in: Money,
  out: Money,
  closing: Money.nullable(),
  /** The day's net movements by cash movement type (non-zero only). */
  by_type: z.record(z.string(), Money),
});
export type DayCloseCashAccount = z.infer<typeof DayCloseCashAccount>;

export const DayCloseShift = z.object({
  id: Uuid,
  number: z.string(),
  status: z.enum(['open', 'closed']),
  cashier: z.object({ id: Uuid, name: z.string() }),
  device_name: z.string().nullable(),
  opened_at: IsoTimestamp,
  closed_at: IsoTimestamp.nullable(),
  opening_float: Money,
  expected: Money,
  counted: Money.nullable(),
  difference: Money.nullable(),
  difference_reason: z.string().nullable(),
  /** The payments of the shift's counted sales (EC-149, D94: voids, collections and deposits apart). */
  payment_totals: DayCloseByMethod,
  /** EC-149: the shift's takings, as on the shift summary. Absent in days closed before EC-149. */
  sales_count: z.number().int().nonnegative().optional(),
  sales_total: Money.optional(),
  tax_total: Money.optional(),
  collections: DayCloseByMethod.optional(),
  deposits: DayCloseByMethod.optional(),
});
export type DayCloseShift = z.infer<typeof DayCloseShift>;

export const DayCloseEta = z.object({
  total: z.number().int().nonnegative(),
  accepted: z.number().int().nonnegative(),
  waiting: z.number().int().nonnegative(),
  cancelled: z.number().int().nonnegative(),
  blocked: z.number().int().nonnegative(),
  send_failed: z.number().int().nonnegative(),
  rejected: z.number().int().nonnegative(),
  all_accepted: z.boolean(),
});
export type DayCloseEta = z.infer<typeof DayCloseEta>;

/** The day's numbers for one branch (decision 2 of the task). */
export const DayCloseTotals = z.object({
  sales: z.object({
    count: z.number().int().nonnegative(),
    total: Money,
    discount_total: Money,
    tax_total: Money,
    paid_by_method: DayCloseByMethod,
    /** The part of installment sales financed by a contract. */
    on_contract: Money,
    /** Voids made this day. Since EC-149 (D94) the voided sales are out of every other sales figure. */
    voided: CountTotal,
  }),
  returns: z.object({
    count: z.number().int().nonnegative(),
    total: Money,
    /** EC-149: the VAT of the returns. Absent in days closed before EC-149. */
    tax_total: Money.optional(),
    refunded_by_method: DayCloseByMethod,
  }),
  collections: z.object({
    count: z.number().int().nonnegative(),
    total: Money,
    principal: Money,
    profit: Money,
    by_method: DayCloseByMethod,
    /** Collected into collector wallets (N06). */
    in_field: Money,
    reversed: CountTotal,
  }),
  expenses: z.object({
    count: z.number().int().nonnegative(),
    total: Money,
    by_category: z.array(z.object({ category_id: Uuid, name: z.string(), total: Money })),
    reversed: CountTotal,
  }),
  supplier_payments: CountTotal.extend({ reversed: CountTotal }),
  supplier_refunds: CountTotal,
  cash: z.object({
    accounts: z.array(DayCloseCashAccount),
    /** What physically sits in the branch: its safes, drawers and collector wallets. */
    total_closing_cash: Money,
  }),
  shifts: z.object({ items: z.array(DayCloseShift), difference_total: Money }),
  /** Null for a shop without the eta module. */
  eta: DayCloseEta.nullable(),
});
export type DayCloseTotals = z.infer<typeof DayCloseTotals>;

const EmployeeRef = z.object({ id: Uuid, name: z.string().nullable() });

/** A stored day close (`GET /api/day-closes/:id`, and the answer of close and reopen). */
export const DayClose = z.object({
  id: Uuid,
  branch_id: Uuid,
  branch_name: z.string(),
  business_date: BusinessDate,
  status: z.enum(['closed', 'reopened']),
  totals: DayCloseTotals,
  issues: z.array(DayCloseIssue),
  note: z.string().nullable(),
  closed_by: EmployeeRef,
  closed_at: IsoTimestamp,
  reopened_by: EmployeeRef.nullable(),
  reopened_at: IsoTimestamp.nullable(),
  reopen_reason: z.string().nullable(),
  /** Closed days only: the live numbers no longer equal the snapshot (a bug or a manual change). */
  drift: z.boolean(),
});
export type DayClose = z.infer<typeof DayClose>;

/** `GET /api/day-closes/preview`: the live numbers of an open or reopened day. */
export const DayClosePreview = z.object({
  branch_id: Uuid,
  branch_name: z.string(),
  business_date: BusinessDate,
  status: z.enum(['open', 'reopened']),
  is_today: z.boolean(),
  totals: DayCloseTotals,
  issues: z.array(DayCloseIssue),
  /** Sent back unchanged by `POST /api/day-closes`. */
  hash: z.string().regex(/^[0-9a-f]{32}$/),
  /** A reopened day: its last stored close. */
  last_close: DayClose.omit({ drift: true }).nullable(),
});
export type DayClosePreview = z.infer<typeof DayClosePreview>;

export const DayClosePreviewQuery = z.object({ branch_id: Uuid, date: BusinessDate }).strict();
export type DayClosePreviewQuery = z.infer<typeof DayClosePreviewQuery>;

export const DayCloseListQuery = z
  .object({
    branch_id: Uuid.optional(),
    from: BusinessDate.optional(),
    to: BusinessDate.optional(),
    status: DayCloseStatus.optional(),
  })
  .strict();
export type DayCloseListQuery = z.infer<typeof DayCloseListQuery>;

export const DayCloseListItem = z.object({
  branch_id: Uuid,
  branch_name: z.string(),
  business_date: BusinessDate,
  status: DayCloseStatus,
  /** The day_closes row, when the day was ever closed. */
  id: Uuid.nullable(),
  closed_by_name: z.string().nullable(),
  closed_at: IsoTimestamp.nullable(),
  sales_total: Money,
  /** Blocking and warning issues: of the stored close, else of the last nightly check (null: none yet). */
  issues_count: z.number().int().nonnegative().nullable(),
});
export type DayCloseListItem = z.infer<typeof DayCloseListItem>;

export const DayCloseListResponse = z.object({
  items: z.array(DayCloseListItem),
  from: BusinessDate,
  to: BusinessDate,
});
export type DayCloseListResponse = z.infer<typeof DayCloseListResponse>;

export const DayCloseIdParams = z.object({ id: Uuid }).strict();
export type DayCloseIdParams = z.infer<typeof DayCloseIdParams>;

export const DAY_CLOSE_NOTE_MAX_LENGTH = 500;

/** `POST /api/day-closes`. A note (3-500) is required when the day has warnings. */
export const CloseDayBody = z
  .object({
    branch_id: Uuid,
    business_date: BusinessDate,
    preview_hash: z.string().regex(/^[0-9a-f]{32}$/),
    note: z.string().trim().max(DAY_CLOSE_NOTE_MAX_LENGTH).nullable().optional(),
  })
  .strict();
export type CloseDayBody = z.infer<typeof CloseDayBody>;

/** `POST /api/day-closes/:id/reopen` (`day.reopen`). */
export const ReopenDayBody = z.object({ reason: z.string().trim().min(3).max(500) }).strict();
export type ReopenDayBody = z.infer<typeof ReopenDayBody>;

/** `GET /api/day-closes/alerts`: branches with days not closed or with findings of the night. */
export const DayCloseAlerts = z.object({
  branches: z.array(
    z.object({
      branch_id: Uuid,
      branch_name: z.string(),
      /** Days with activity in the last 14 days (today left out) that are not closed, oldest first. */
      unclosed_days: z.array(BusinessDate),
      last_check: z
        .object({
          business_date: BusinessDate,
          checked_at: IsoTimestamp,
          drift: z.boolean(),
          warnings: z.number().int().nonnegative(),
          critical: z.number().int().nonnegative(),
        })
        .nullable(),
    }),
  ),
});
export type DayCloseAlerts = z.infer<typeof DayCloseAlerts>;

/** DAY_ALREADY_CLOSED (409): the stored close to open instead. */
export const DayAlreadyClosedDetail = z.object({ id: Uuid });
export type DayAlreadyClosedDetail = z.infer<typeof DayAlreadyClosedDetail>;

/** DAY_CLOSE_BLOCKED (409): the blocking issues. */
export const DayCloseBlockedDetail = z.object({ issues: z.array(DayCloseIssue) });
export type DayCloseBlockedDetail = z.infer<typeof DayCloseBlockedDetail>;

/** Issues the closer must acknowledge with a note. */
export function dayCloseNeedsNote(issues: readonly DayCloseIssue[]): boolean {
  return issues.some((i) => i.severity === 'warning');
}

/** Issues that stop the close. */
export function dayCloseBlockers(issues: readonly DayCloseIssue[]): DayCloseIssue[] {
  return issues.filter((i) => i.severity === 'blocking');
}
