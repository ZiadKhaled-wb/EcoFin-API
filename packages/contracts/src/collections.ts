import { z } from 'zod';
import { PositiveMoney } from './cash.js';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { ContractStatus, ScheduleLineStatus } from './customerAccount.js';
import { compareMoney, sumMoney } from './money.js';
import { SALE_MAX_BANK_TRANSFERS, SalePaymentInput } from './sales.js';

/**
 * N03 collections (D78). A customer pays installments on one or several of their contracts in one
 * request, split across cash and bank transfers. The amount of each contract is allocated to its
 * current schedule oldest line first (profit, then principal); a contract can never be paid more
 * than what is left on it. No late fee or penalty of any kind (docs/ISLAMIC_FINANCE_RULES.md rule
 * 4) and no store credit. A collection is not a sale. A wrong collection can be reversed on its
 * own business day (collection.reverse).
 */

/** At most this many contracts in one collection. */
export const COLLECTION_MAX_CONTRACTS = 10;
/** At most this many payment lines: one cash and three bank transfers. */
export const COLLECTION_MAX_PAYMENTS = 4;

/** A collection payment line: S02's cash or bank transfer line (store credit is not a method). */
export const CollectionPaymentInput = z.discriminatedUnion('method', [
  SalePaymentInput.options[0],
  SalePaymentInput.options[1],
]);
export type CollectionPaymentInput = z.infer<typeof CollectionPaymentInput>;

/** One contract of the collection: what the cashier puts on it and what the screen saw left. */
export const CollectionContractInput = z
  .object({
    contract_id: Uuid,
    amount: PositiveMoney,
    /** The contract's `remaining` the screen showed; a change since then is COLLECTION_DUE_CHANGED. */
    expected_remaining: Money.optional(),
  })
  .strict();
export type CollectionContractInput = z.infer<typeof CollectionContractInput>;

export const CollectionBody = z
  .object({
    customer_id: Uuid,
    contracts: z.array(CollectionContractInput).min(1).max(COLLECTION_MAX_CONTRACTS),
    payments: z.array(CollectionPaymentInput).min(1).max(COLLECTION_MAX_PAYMENTS),
  })
  .strict()
  .superRefine((body, ctx) => {
    const ids = body.contracts.map((c) => c.contract_id);
    if (new Set(ids).size !== ids.length) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['contracts'],
        message: 'A contract is listed twice',
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
    body.payments.forEach((p, i) => {
      if (
        p.method === 'cash' &&
        p.tendered !== undefined &&
        compareMoney(p.tendered, p.amount) < 0
      ) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['payments', i, 'tendered'],
          message: 'The customer must hand over at least the amount',
        });
      }
    });
    const total = sumMoney(body.contracts.map((c) => c.amount));
    const paid = sumMoney(body.payments.map((p) => p.amount));
    if (compareMoney(total, paid) !== 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['payments'],
        message: 'The payment lines must add up to the contracts’ amounts',
      });
    }
  });
export type CollectionBody = z.infer<typeof CollectionBody>;

export const CollectionReverseBody = z
  .object({ reason: z.string().trim().min(3).max(500) })
  .strict();
export type CollectionReverseBody = z.infer<typeof CollectionReverseBody>;

/** One schedule line an amount pays: its profit first, then its principal. */
export const CollectionAllocationLine = z.object({
  seq: z.number().int().min(1),
  due_date: BusinessDate,
  profit: Money,
  principal: Money,
  amount: Money,
  /** The line has nothing left after this amount. */
  pays_off: z.boolean(),
});
export type CollectionAllocationLine = z.infer<typeof CollectionAllocationLine>;

export const CollectionAllocation = z.object({
  lines: z.array(CollectionAllocationLine),
  completes_contract: z.boolean(),
});
export type CollectionAllocation = z.infer<typeof CollectionAllocation>;

/** What is due on a contract's current schedule (no fees: rule 4). */
export const ContractDue = z.object({
  overdue_amount: Money,
  overdue_lines: z.number().int().min(0),
  due_today: Money,
  next_due_date: BusinessDate.nullable(),
  next_due_amount: Money,
  /** What closes the contract. */
  remaining: Money,
});
export type ContractDue = z.infer<typeof ContractDue>;

export const ContractDueLine = z.object({
  seq: z.number().int().min(1),
  due_date: BusinessDate,
  amount: Money,
  paid: Money,
  remaining: Money,
  status: ScheduleLineStatus,
  days_late: z.number().int().min(0),
});
export type ContractDueLine = z.infer<typeof ContractDueLine>;

const CustomerRef = z.object({ id: Uuid, name: z.string(), phone: z.string().nullable() });

export const CollectionPreviewQuery = z.object({ amount: PositiveMoney.optional() }).strict();
export type CollectionPreviewQuery = z.infer<typeof CollectionPreviewQuery>;

/** `GET /api/contracts/:id/collection`: what is due, and what `amount` would pay. */
export const CollectionPreview = z.object({
  contract: z.object({
    id: Uuid,
    number: z.string(),
    status: ContractStatus,
    customer: CustomerRef,
    branch_id: Uuid,
    total_payable: Money,
  }),
  due: ContractDue,
  lines: z.array(ContractDueLine),
  allocation: CollectionAllocation.extend({ exceeds_remaining: z.boolean() }).nullable(),
});
export type CollectionPreview = z.infer<typeof CollectionPreview>;

/** `GET /api/contracts`: `open` = active and rescheduled (the default); `all` = every status. */
export const ContractListStatus = z.enum(['open', 'all', ...ContractStatus.options]);
export type ContractListStatus = z.infer<typeof ContractListStatus>;

export const ContractListQuery = z
  .object({
    q: z.string().trim().min(1).max(100).optional(),
    customer_id: Uuid.optional(),
    status: ContractListStatus.optional(),
    branch_id: Uuid.optional(),
    // A query string, or the boolean it became once the route's validation parsed it.
    overdue: z
      .union([z.boolean(), z.enum(['true', 'false']).transform((v) => v === 'true')])
      .optional(),
    limit: z.coerce.number().int().min(1).max(100).optional(),
    cursor: z.string().min(1).max(200).optional(),
  })
  .strict();
export type ContractListQuery = z.infer<typeof ContractListQuery>;
export type ContractListQueryInput = z.input<typeof ContractListQuery>;

export const ContractListItem = z.object({
  id: Uuid,
  number: z.string(),
  status: ContractStatus,
  customer: CustomerRef,
  branch_id: Uuid,
  total_payable: Money,
  paid: Money,
  remaining: Money,
  overdue_amount: Money,
  max_days_late: z.number().int().nullable(),
  next_due_date: BusinessDate.nullable(),
});
export type ContractListItem = z.infer<typeof ContractListItem>;

export const ContractListPage = z.object({
  items: z.array(ContractListItem),
  next_cursor: z.string().nullable(),
});
export type ContractListPage = z.infer<typeof ContractListPage>;

export const CollectionPaymentLine = z.object({
  id: Uuid,
  number: z.string(),
  method: z.enum(['cash', 'bank_transfer']),
  amount: Money,
  tendered: Money.nullable(),
  change: Money.nullable(),
  reference: z.string().nullable(),
  cash_account_id: Uuid.nullable(),
});
export type CollectionPaymentLine = z.infer<typeof CollectionPaymentLine>;

export const CollectionContract = z.object({
  id: Uuid,
  number: z.string(),
  amount: Money,
  /** The contract's status today. */
  status: ContractStatus,
  allocation: CollectionAllocation,
  /** The contract right after this collection. */
  after: z.object({
    remaining: Money,
    next_due_date: BusinessDate.nullable(),
    next_due_amount: Money,
  }),
});
export type CollectionContract = z.infer<typeof CollectionContract>;

export const CollectionReversal = z.object({
  id: Uuid,
  number: z.string(),
  reversed_at: IsoTimestamp,
  reversed_by_name: z.string().nullable(),
  reason: z.string(),
});
export type CollectionReversal = z.infer<typeof CollectionReversal>;

/** The receipt print log (S04's pattern): the first print is the original. */
export const CollectionPrint = z.object({ print_no: z.number().int().min(1), copy: z.boolean() });
export type CollectionPrint = z.infer<typeof CollectionPrint>;

/** A collection: the answer of `POST /api/collections` and the receipt. `id` is the receipt row. */
export const Collection = z.object({
  id: Uuid,
  number: z.string(),
  business_date: BusinessDate,
  paid_at: IsoTimestamp,
  received_by_name: z.string().nullable(),
  branch_id: Uuid,
  branch_name: z.string(),
  shift_id: Uuid.nullable(),
  amount: Money,
  customer: CustomerRef,
  payments: z.array(CollectionPaymentLine),
  contracts: z.array(CollectionContract),
  reversal: CollectionReversal.nullable(),
  receipt_prints: z.number().int().min(0),
  print: CollectionPrint.optional(),
});
export type Collection = z.infer<typeof Collection>;

export const CollectionIdParams = z.object({ id: Uuid }).strict();
export type CollectionIdParams = z.infer<typeof CollectionIdParams>;

// Error details.
export const ContractNotOpenDetail = z.object({ contract_id: Uuid, status: ContractStatus });
export type ContractNotOpenDetail = z.infer<typeof ContractNotOpenDetail>;
export const CollectionRemainingDetail = z.object({ contract_id: Uuid, remaining: Money });
export type CollectionRemainingDetail = z.infer<typeof CollectionRemainingDetail>;
export const COLLECTION_NOT_REVERSIBLE_REASONS = [
  'already_reversed',
  'not_same_day',
  'shift_closed',
  'not_latest',
  /** N05: the collection paid an early settlement (its waiver can't be undone this way). */
  'settlement',
  /** N05: the contract was rescheduled or settled after this collection. */
  'contract_changed',
  /** N06: a field collection whose cash was handed in (settled) after it. */
  'handed_in',
] as const;
export const CollectionNotReversibleDetail = z.object({
  reason: z.enum(COLLECTION_NOT_REVERSIBLE_REASONS),
  contract_id: Uuid.optional(),
});
export type CollectionNotReversibleDetail = z.infer<typeof CollectionNotReversibleDetail>;
