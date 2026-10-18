import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { Collection, CollectionPaymentInput, COLLECTION_MAX_PAYMENTS } from './collections.js';
import { ContractStatus, ScheduleLineStatus } from './customerAccount.js';
import { Contract, InstallmentViolation } from './installments.js';
import { compareMoney, subtractMoney, sumMoney } from './money.js';
import { SALE_MAX_BANK_TRANSFERS } from './sales.js';
import { InstallmentFrequency } from './settings.js';

/**
 * N05 early settlement, rescheduling, write-off (D80). Three controlled changes to an open
 * installment contract; each leaves a contract change row and nothing is edited:
 * - early settlement: the customer pays what is left today; a manager may waive part of the
 *   profit of the installments not yet due (docs/ISLAMIC_FINANCE_RULES.md rule 6: a voluntary
 *   waiver at settlement time, never promised; the policy's rule is only a suggestion);
 * - reschedule: what is left (principal and profit, exactly: rule 5) spread over a new schedule;
 *   the old schedule stays, superseded;
 * - write-off (the owner only): what is left is marked as lost.
 * Words: profit and "profit waived", never interest or discount.
 */

export const CONTRACT_CHANGE_KINDS = [
  'early_settlement',
  'reschedule',
  'write_off',
  'return_adjustment',
] as const;
/** `return_adjustment` exists in the database for the sales-return slice; N05 never makes one. */
export const ContractChangeKind = z.enum(CONTRACT_CHANGE_KINDS);
export type ContractChangeKind = z.infer<typeof ContractChangeKind>;

const NonNegativeMoney = Money.refine((v) => !v.startsWith('-'), 'Must not be negative');
const Reason = z.string().trim().min(3).max(300);

export const ContractChange = z.object({
  id: Uuid,
  kind: ContractChangeKind,
  contract_id: Uuid,
  old_version: z.number().int().positive(),
  /** The schedule version it made (settlement, reschedule); null for a write-off. */
  new_version: z.number().int().positive().nullable(),
  /** What was left on the contract when the change was made. */
  amount: Money.nullable(),
  principal_amount: Money.nullable(),
  profit_amount: Money.nullable(),
  /** Profit waived at an early settlement (0 otherwise). */
  profit_waived: Money,
  reason: z.string(),
  business_date: BusinessDate.nullable(),
  created_at: IsoTimestamp,
  created_by: z.object({ id: Uuid.nullable(), name: z.string().nullable() }),
  /** The manager who waived profit, or the owner who wrote off. */
  approved_by: Uuid.nullable(),
  /** The settlement's collection receipt. */
  payment_id: Uuid.nullable(),
});
export type ContractChange = z.infer<typeof ContractChange>;

// ---------------------------------------------------------------------------------------------
// Early settlement

/** `GET /api/contracts/:id/settlement-quote`. */
export const SettlementQuote = z.object({
  contract_id: Uuid,
  number: z.string(),
  status: ContractStatus,
  /** The payoff: everything left on the current schedule. */
  remaining: Money,
  principal_left: Money,
  profit_left: Money,
  /** Profit left on the installments not yet due. */
  future_profit: Money,
  /** The policy's suggestion, never a promise (rule 6). */
  suggested_waiver: Money,
  /** At most the profit not yet due, and something is always paid. */
  max_waiver: Money,
  policy_rule: z.object({
    early_settlement_rule: z.enum([
      'no_discount',
      'waive_future_profit',
      'percent_of_future_profit',
    ]),
    early_settlement_pct: z.string().nullable(),
  }),
});
export type SettlementQuote = z.infer<typeof SettlementQuote>;

/** `POST /api/contracts/:id/settle` (Idempotency-Key). Payments add up to payoff − waiver. */
export const SettleBody = z
  .object({
    waiver: NonNegativeMoney,
    /** Required when something is waived. */
    reason: Reason.optional(),
    /** The quote's `remaining`; a change since then is COLLECTION_DUE_CHANGED. */
    expected_remaining: NonNegativeMoney,
    payments: z.array(CollectionPaymentInput).min(1).max(COLLECTION_MAX_PAYMENTS),
  })
  .strict()
  .superRefine((body, ctx) => {
    if (compareMoney(body.waiver, '0') > 0 && body.reason === undefined) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['reason'],
        message: 'A waiver needs a reason',
      });
    }
    const cash = body.payments.filter((p) => p.method === 'cash');
    const bank = body.payments.filter((p) => p.method === 'bank_transfer');
    if (cash.length > 1 || bank.length > SALE_MAX_BANK_TRANSFERS) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['payments'],
        message: 'At most one cash and three bank transfer lines',
      });
    }
    const due = subtractMoney(body.expected_remaining, body.waiver);
    if (compareMoney(sumMoney(body.payments.map((p) => p.amount)), due) !== 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['payments'],
        message: 'The payment lines must add up to the payoff minus the waiver',
      });
    }
  });
export type SettleBody = z.infer<typeof SettleBody>;

export const SettleResponse = z.object({ change: ContractChange, collection: Collection });
export type SettleResponse = z.infer<typeof SettleResponse>;

// ---------------------------------------------------------------------------------------------
// Rescheduling

export const ReschedulePreviewBody = z
  .object({
    installments_count: z.number().int().min(1).max(520),
    frequency: InstallmentFrequency,
    first_due_date: BusinessDate,
  })
  .strict();
export type ReschedulePreviewBody = z.infer<typeof ReschedulePreviewBody>;

export const RescheduleLine = z.object({
  seq: z.number().int().positive(),
  due_date: BusinessDate,
  principal: Money,
  profit: Money,
  amount: Money,
});
export type RescheduleLine = z.infer<typeof RescheduleLine>;

/** `POST /api/contracts/:id/reschedule/preview`: the new lines add up to what is left. */
export const ReschedulePreview = z.object({
  remaining: Money,
  principal_left: Money,
  profit_left: Money,
  lines: z.array(RescheduleLine),
  violations: z.array(InstallmentViolation),
});
export type ReschedulePreview = z.infer<typeof ReschedulePreview>;

/** `POST /api/contracts/:id/reschedule` (Idempotency-Key). */
export const RescheduleBody = z
  .object({
    installments_count: z.number().int().min(1).max(520),
    frequency: InstallmentFrequency,
    first_due_date: BusinessDate,
    reason: Reason,
    expected_remaining: NonNegativeMoney,
  })
  .strict();
export type RescheduleBody = z.infer<typeof RescheduleBody>;

/** The answer of a reschedule and of a write-off: the change and the contract now. */
export const ContractChangeResponse = z.object({ change: ContractChange, contract: Contract });
export type ContractChangeResponse = z.infer<typeof ContractChangeResponse>;

// ---------------------------------------------------------------------------------------------
// Write-off (the owner only)

export const WriteOffBody = z
  .object({ reason: Reason, expected_remaining: NonNegativeMoney })
  .strict();
export type WriteOffBody = z.infer<typeof WriteOffBody>;

// ---------------------------------------------------------------------------------------------
// History and the shop's list

export const ContractVersionLine = z.object({
  seq: z.number().int().positive(),
  due_date: BusinessDate,
  principal: Money,
  profit: Money,
  amount: Money,
  paid: Money,
  remaining: Money,
  status: ScheduleLineStatus,
});
export type ContractVersionLine = z.infer<typeof ContractVersionLine>;

export const ContractVersion = z.object({
  version: z.number().int().positive(),
  superseded: z.boolean(),
  /** The change that made this version (null for the first). */
  change_id: Uuid.nullable(),
  lines: z.array(ContractVersionLine),
});
export type ContractVersion = z.infer<typeof ContractVersion>;

/** `GET /api/contracts/:id/changes`: newest first. */
export const ContractChangeHistory = z.object({
  changes: z.array(ContractChange),
  versions: z.array(ContractVersion),
});
export type ContractChangeHistory = z.infer<typeof ContractChangeHistory>;

/** `GET /api/contract-changes`: filters. Newest first. */
export const ContractChangeListQuery = z
  .object({
    kind: ContractChangeKind.optional(),
    branch_id: Uuid.optional(),
    from: BusinessDate.optional(),
    to: BusinessDate.optional(),
    limit: z.coerce.number().int().min(1).max(100).optional(),
    cursor: z.string().min(1).max(200).optional(),
  })
  .strict()
  .refine((q) => q.from === undefined || q.to === undefined || q.from <= q.to, {
    message: '`from` must not be after `to`',
    path: ['to'],
  });
export type ContractChangeListQuery = z.infer<typeof ContractChangeListQuery>;
export type ContractChangeListQueryInput = z.input<typeof ContractChangeListQuery>;

export const ContractChangeListItem = ContractChange.extend({
  contract: z.object({ id: Uuid, number: z.string(), branch_id: Uuid }),
  customer: z.object({ id: Uuid, name: z.string() }),
});
export type ContractChangeListItem = z.infer<typeof ContractChangeListItem>;

export const ContractChangeTotals = z.object({
  kind: ContractChangeKind,
  count: z.number().int().min(0),
  amount: Money,
  profit_waived: Money,
});
export type ContractChangeTotals = z.infer<typeof ContractChangeTotals>;

export const ContractChangeListPage = z.object({
  items: z.array(ContractChangeListItem),
  next_cursor: z.string().nullable(),
  totals: z.array(ContractChangeTotals),
});
export type ContractChangeListPage = z.infer<typeof ContractChangeListPage>;

// Error details.
/** WAIVER_TOO_HIGH: the waiver is above the profit not yet due. */
export const WaiverTooHighDetail = z.object({ max_waiver: Money });
export type WaiverTooHighDetail = z.infer<typeof WaiverTooHighDetail>;
