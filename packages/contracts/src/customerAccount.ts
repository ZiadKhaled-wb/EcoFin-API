import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { CustomerStatus } from './customers.js';
import { InstallmentFrequency } from './settings.js';
import { ContractMigrationSource } from './migration.js';

/**
 * R02 customer account (D74). Read only: one page shows everything about a customer's money.
 *
 * - **Contract total** = the current (not superseded) schedule lines + what was paid on superseded
 *   lines; for a contract never rescheduled it equals `total_payable`.
 * - **Open balance** (over active and rescheduled contracts) = contract totals − payments on their
 *   schedule lines − returns settled against the contract (`refund_method = contract_adjustment`).
 *   Late fees stay apart: `total_due = open_balance + fees_due`.
 * - **Statement:** balance > 0 = the customer owes the shop. Store-credit payments are not rows
 *   (the credit was counted when it was given), so without dates the closing balance equals
 *   `total_due − store_credit`.
 *
 * Purchases come from S07's sales search (`customer_id`), guarantors from R04 and documents from
 * the F14 files list; they are not repeated here.
 */

/** A statement covers at most three years. */
export const CUSTOMER_STATEMENT_MAX_YEARS = 3;

export const CustomerAccountHead = z.object({
  id: Uuid,
  full_name: z.string(),
  status: CustomerStatus,
  phones: z.array(z.string()),
});
export type CustomerAccountHead = z.infer<typeof CustomerAccountHead>;

export const CustomerOpenBalance = z.object({
  contract_totals: Money,
  payments: Money,
  returns: Money,
  open_balance: Money,
  fees_due: Money,
  total_due: Money,
});
export type CustomerOpenBalance = z.infer<typeof CustomerOpenBalance>;

/** The open balance plus the store credit and R03's limit (available is never below 0). */
export const CustomerAccountBalance = CustomerOpenBalance.extend({
  store_credit: Money,
  credit_limit: Money,
  available: Money,
});
export type CustomerAccountBalance = z.infer<typeof CustomerAccountBalance>;

export const CustomerAging = z.object({
  not_yet_due: Money,
  late_1_30: Money,
  late_31_60: Money,
  late_61_90: Money,
  late_90_plus: Money,
});
export type CustomerAging = z.infer<typeof CustomerAging>;

/** `next_due_date` is the earliest unpaid current line (it may be in the past). */
export const CustomerOverdue = z.object({
  overdue_amount: Money,
  overdue_lines: z.number().int().min(0),
  max_days_late: z.number().int().min(0).nullable(),
  next_due_date: BusinessDate.nullable(),
  next_due_amount: Money.nullable(),
  aging: CustomerAging,
});
export type CustomerOverdue = z.infer<typeof CustomerOverdue>;

export const CustomerAccountTotals = z.object({
  /** Sales that are not voided. */
  purchases_count: z.number().int().min(0),
  purchases_total: Money,
  /** Returns, voids and exchanges. */
  returns_count: z.number().int().min(0),
  returns_total: Money,
  /** Cash and bank transfer payments that were not reversed (store credit is not money in). */
  payments_in: Money,
  payments_out: Money,
  last_purchase_at: IsoTimestamp.nullable(),
  last_payment_at: IsoTimestamp.nullable(),
});
export type CustomerAccountTotals = z.infer<typeof CustomerAccountTotals>;

export const ContractStatus = z.enum([
  'active',
  'completed',
  'rescheduled',
  'written_off',
  'returned',
]);
export type ContractStatus = z.infer<typeof ContractStatus>;

const BranchRef = z.object({ id: Uuid, name: z.string() });

export const CustomerContractSummary = z.object({
  id: Uuid,
  number: z.string(),
  status: ContractStatus,
  branch: BranchRef,
  sale_id: Uuid.nullable(),
  sale_number: z.string().nullable(),
  issued_at: IsoTimestamp,
  is_migrated: z.boolean(),
  /** M02: what the old system remembered, null on a contract made here. */
  migration_source: ContractMigrationSource.nullable().optional(),
  cash_price: Money,
  down_payment: Money,
  financed_amount: Money,
  markup_amount: Money,
  total_payable: Money,
  contract_total: Money,
  paid: Money,
  remaining: Money,
  fees_due: Money,
  overdue_amount: Money,
  overdue_lines: z.number().int().min(0),
  max_days_late: z.number().int().min(0).nullable(),
  next_due_date: BusinessDate.nullable(),
  installments_count: z.number().int().positive(),
  frequency: InstallmentFrequency,
  first_due_date: BusinessDate,
});
export type CustomerContractSummary = z.infer<typeof CustomerContractSummary>;

export const PaymentDirection = z.enum(['in', 'out']);
export type PaymentDirection = z.infer<typeof PaymentDirection>;
export const PaymentAllocationKind = z.enum(['sale', 'schedule_line', 'charge', 'order', 'return']);
export type PaymentAllocationKind = z.infer<typeof PaymentAllocationKind>;

export const CustomerPaymentSummary = z.object({
  id: Uuid,
  number: z.string(),
  direction: PaymentDirection,
  method: z.enum(['cash', 'bank_transfer', 'store_credit']),
  amount: Money,
  reference: z.string().nullable(),
  received_at: IsoTimestamp,
  business_date: BusinessDate,
  branch: BranchRef,
  allocated_to: z.array(
    z.object({
      kind: PaymentAllocationKind,
      /** A schedule line is "<contract number> #<seq>". */
      document_number: z.string().nullable(),
      amount: Money,
    }),
  ),
});
export type CustomerPaymentSummary = z.infer<typeof CustomerPaymentSummary>;

export const CustomerReturnSummary = z.object({
  id: Uuid,
  number: z.string(),
  kind: z.enum(['return', 'void', 'exchange']),
  refund_method: z.enum(['cash', 'bank_transfer', 'store_credit', 'contract_adjustment']),
  total: Money,
  sale_id: Uuid,
  sale_number: z.string(),
  business_date: BusinessDate,
  created_at: IsoTimestamp,
});
export type CustomerReturnSummary = z.infer<typeof CustomerReturnSummary>;

export const CustomerAccount = z.object({
  customer: CustomerAccountHead,
  balance: CustomerAccountBalance,
  overdue: CustomerOverdue,
  totals: CustomerAccountTotals,
  /** Every contract, newest first. */
  contracts: z.array(CustomerContractSummary),
  /** The last 10 payments that were not reversed, newest first. */
  recent_payments: z.array(CustomerPaymentSummary),
  /** The last 10 returns, voids and exchanges, newest first. */
  recent_returns: z.array(CustomerReturnSummary),
  /** Files on the customer and on its contracts. */
  documents_count: z.number().int().min(0),
});
export type CustomerAccount = z.infer<typeof CustomerAccount>;

export const ScheduleLineStatus = z.enum([
  'upcoming',
  'due',
  'partly_paid',
  'overdue',
  'paid',
  'closed',
  'superseded',
]);
export type ScheduleLineStatus = z.infer<typeof ScheduleLineStatus>;

export const CustomerScheduleLine = z.object({
  id: Uuid,
  version: z.number().int().positive(),
  seq: z.number().int().positive(),
  due_date: BusinessDate,
  principal: Money,
  profit: Money,
  amount: Money,
  paid: Money,
  remaining: Money,
  fees_due: Money,
  /** 0 unless the line is overdue. */
  days_late: z.number().int().min(0),
  status: ScheduleLineStatus,
  superseded: z.boolean(),
});
export type CustomerScheduleLine = z.infer<typeof CustomerScheduleLine>;

export const CustomerContractCharge = z.object({
  id: Uuid,
  schedule_line_id: Uuid,
  seq: z.number().int().positive(),
  kind: z.enum(['late_fee']),
  assessed_on: BusinessDate,
  amount: Money,
  waived: Money,
  paid: Money,
  due: Money,
});
export type CustomerContractCharge = z.infer<typeof CustomerContractCharge>;

/** The current lines first, then the superseded ones (newest version first). */
export const CustomerContractSchedule = z.object({
  contract: CustomerContractSummary,
  lines: z.array(CustomerScheduleLine),
  charges: z.array(CustomerContractCharge),
});
export type CustomerContractSchedule = z.infer<typeof CustomerContractSchedule>;

export const CustomerContractParams = z.object({ id: Uuid, contractId: Uuid }).strict();
export type CustomerContractParams = z.infer<typeof CustomerContractParams>;

function addYears(date: string, years: number): string {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number];
  const t = new Date(Date.UTC(y + years, m - 1, d));
  return t.toISOString().slice(0, 10);
}

export const CustomerStatementQuery = z
  .object({ from: BusinessDate.optional(), to: BusinessDate.optional() })
  .strict()
  .refine((q) => q.from === undefined || q.to === undefined || q.from <= q.to, {
    message: '`from` must not be after `to`',
    path: ['from'],
  })
  .refine(
    (q) =>
      q.from === undefined ||
      q.to === undefined ||
      q.to <= addYears(q.from, CUSTOMER_STATEMENT_MAX_YEARS),
    { message: 'a statement covers at most three years', path: ['to'] },
  );
export type CustomerStatementQuery = z.infer<typeof CustomerStatementQuery>;

export const CustomerStatementKind = z.enum([
  'sale',
  'contract',
  'payment_in',
  'payment_out',
  'payment_reversal',
  'return',
  'fee',
  'fee_waiver',
  /** N05: profit waived at an early settlement (a credit). */
  'profit_waiver',
  /** N05: a written-off balance (a credit). */
  'write_off',
]);
export type CustomerStatementKind = z.infer<typeof CustomerStatementKind>;

/**
 * `detail`: the payment method (payments), the return kind (returns), the sale number (contracts),
 * the charge kind (fees) or the waiver reason. `number` of a fee or a waiver is its contract's.
 * `balance` is the running total after the row.
 */
export const CustomerStatementRow = z.object({
  date: BusinessDate,
  kind: CustomerStatementKind,
  document_id: Uuid,
  number: z.string(),
  detail: z.string().nullable(),
  reference: z.string().nullable(),
  debit: Money,
  credit: Money,
  balance: Money,
});
export type CustomerStatementRow = z.infer<typeof CustomerStatementRow>;

/** Shop-wide. Without dates `closing_balance` = `total_due − store_credit` of the account. */
export const CustomerStatement = z.object({
  customer: CustomerAccountHead,
  from: BusinessDate.nullable(),
  to: BusinessDate.nullable(),
  opening_balance: Money,
  closing_balance: Money,
  totals: z.object({ debit: Money, credit: Money }),
  rows: z.array(CustomerStatementRow),
});
export type CustomerStatement = z.infer<typeof CustomerStatement>;
