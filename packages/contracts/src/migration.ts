import { z } from 'zod';
import { BusinessDate, IsoTimestamp, Money, Uuid } from './common.js';
import { ImportJob, ImportUserRef } from './imports.js';

/**
 * M02 opening balances (D85). A shop brings its open installment debts and its opening cash
 * through the M01 import (kinds `opening_contracts` and `opening_cash`); this file is the rest:
 * the reconciliation report, the owner's sign-off against the old records' total, and the undo of
 * a wrong batch. A migrated contract stores only what is left of the installment price (never
 * interest, never a late fee). Every money value is a decimal string from the server.
 * Words: installment price (سعر التقسيط), profit (ربح).
 */

/** What a migrated contract remembers of the old system (`Contract.migration_source`). */
export const ContractMigrationSource = z.object({
  /** The old system's contract number (searchable; unique per shop among migrated contracts). */
  contract_ref: z.string(),
  contract_date: BusinessDate,
  /** The installment price the customer signed for. */
  original_total: Money,
  /** Everything paid before the migration, down payment included. */
  paid_before: Money,
  notes: z.string().optional(),
  /** Set when the batch was reversed (the contract is then written off). */
  reversed: z.boolean().optional(),
});
export type ContractMigrationSource = z.infer<typeof ContractMigrationSource>;

// ---------------------------------------------------------------------------------------------
// The reconciliation report

export const MIGRATION_REPORT_FORMATS = ['json', 'csv'] as const;

/** `GET /api/migration/report` */
export const MigrationReportQuery = z
  .object({
    batch_id: Uuid.optional(),
    branch_id: Uuid.optional(),
    customer_id: Uuid.optional(),
    format: z.enum(MIGRATION_REPORT_FORMATS).default('json'),
  })
  .strict();
export type MigrationReportQuery = z.infer<typeof MigrationReportQuery>;

const MigrationAmounts = {
  contracts: z.number().int().min(0),
  /** The installment price of the old contracts. */
  original_total: Money,
  paid_before: Money,
  /** What the batch imported (what was left on the import day); frozen. */
  imported_total: Money,
  /** What is left today (from the contracts' balances). */
  open_now: Money,
  overdue_now: Money,
  /** Collected through EcoFin since the migration. */
  collected_since: Money,
};

export const MigrationReportTotals = z.object({
  ...MigrationAmounts,
  customers: z.number().int().min(0),
});
export type MigrationReportTotals = z.infer<typeof MigrationReportTotals>;

export const MigrationReportCustomer = z.object({
  customer_id: Uuid,
  name: z.string(),
  /** Masked unless the caller holds `customer.view_pii`. */
  national_id: z.string().nullable(),
  ...MigrationAmounts,
});
export type MigrationReportCustomer = z.infer<typeof MigrationReportCustomer>;

export const MigrationReportBranch = z.object({
  branch_id: Uuid,
  name: z.string(),
  ...MigrationAmounts,
});
export type MigrationReportBranch = z.infer<typeof MigrationReportBranch>;

/** Why a batch cannot be reversed any more. */
export const MIGRATION_BLOCKER_REASONS = [
  'collection',
  'contract_change',
  'legal_case',
  'overdue_action',
] as const;
export const MigrationBlockerReason = z.enum(MIGRATION_BLOCKER_REASONS);
export type MigrationBlockerReason = z.infer<typeof MigrationBlockerReason>;

export const MigrationBlocker = z.object({
  contract_id: Uuid,
  number: z.string(),
  reason: MigrationBlockerReason,
});
export type MigrationBlocker = z.infer<typeof MigrationBlocker>;

export const MigrationReportBatch = z.object({
  id: Uuid,
  kind: z.enum(['opening_contracts', 'opening_cash']),
  created_at: IsoTimestamp,
  file_name: z.string().nullable(),
  contracts: z.number().int().min(0),
  imported_total: Money,
  cash_total: Money,
  reversed: z.boolean(),
  /** The sign-off that covers the batch, if any. */
  signoff_id: Uuid.nullable(),
  can_reverse: z.boolean(),
  blocker: MigrationBlocker.nullable(),
});
export type MigrationReportBatch = z.infer<typeof MigrationReportBatch>;

export const MigrationReportCash = z.object({
  account_id: Uuid,
  name: z.string(),
  kind: z.string(),
  branch_id: Uuid.nullable(),
  branch_name: z.string().nullable(),
  /** The opening balance posted by the imports. */
  opening_posted: Money,
  balance_now: Money,
});
export type MigrationReportCash = z.infer<typeof MigrationReportCash>;

export const MigrationReport = z.object({
  as_of: BusinessDate,
  filters: z.object({
    batch_id: Uuid.optional(),
    branch_id: Uuid.optional(),
    customer_id: Uuid.optional(),
  }),
  totals: MigrationReportTotals,
  /** At most 2000 customers; the totals always cover all of them. */
  customers: z.array(MigrationReportCustomer),
  branches: z.array(MigrationReportBranch),
  batches: z.array(MigrationReportBatch),
  cash: z.array(MigrationReportCash),
  cash_totals: z.object({ opening_posted: Money, balance_now: Money }),
});
export type MigrationReport = z.infer<typeof MigrationReport>;

// ---------------------------------------------------------------------------------------------
// Sign-off

/** A non-negative amount with at most two decimals ("30000" or "30000.00"). */
export const MigrationAmount = z.string().regex(/^\d{1,16}(\.\d{1,2})?$/);

export const MIGRATION_NOTE_MIN_LENGTH = 3;
export const MIGRATION_NOTE_MAX_LENGTH = 500;
export const MIGRATION_REASON_MAX_LENGTH = 300;
export const MIGRATION_SIGNOFF_MAX_BATCHES = 50;

/**
 * `POST /api/migration/sign-offs`. The totals come from the signed paper of the old records. The
 * server compares them with what the batches imported; ANY difference is refused.
 */
export const MigrationSignOffBody = z
  .object({
    expected_open_total: MigrationAmount,
    expected_cash_total: MigrationAmount.optional(),
    batch_ids: z
      .array(Uuid)
      .min(1)
      .max(MIGRATION_SIGNOFF_MAX_BATCHES)
      .refine((ids) => new Set(ids).size === ids.length, 'Duplicate batch'),
    note: z.string().trim().min(MIGRATION_NOTE_MIN_LENGTH).max(MIGRATION_NOTE_MAX_LENGTH),
    /** The scan of the signed paper (F14 file, purpose `other`). */
    signed_file_id: Uuid.optional(),
  })
  .strict();
export type MigrationSignOffBody = z.infer<typeof MigrationSignOffBody>;

export const MigrationSignOff = z.object({
  id: Uuid,
  batch_ids: z.array(Uuid),
  expected_open_total: Money,
  system_open_total: Money,
  expected_cash_total: Money.nullable(),
  system_cash_total: Money,
  note: z.string(),
  signed_file_id: Uuid.nullable(),
  signed_by: ImportUserRef.nullable(),
  signed_at: IsoTimestamp,
});
export type MigrationSignOff = z.infer<typeof MigrationSignOff>;

export const MigrationSignOffList = z.object({ items: z.array(MigrationSignOff) });
export type MigrationSignOffList = z.infer<typeof MigrationSignOffList>;

/** Detail of MIGRATION_TOTAL_MISMATCH (409): nothing was stored. */
export const MigrationTotalMismatchDetail = z.object({
  field: z.enum(['open_total', 'cash_total']),
  expected: Money,
  system: Money,
  /** expected − system (negative when the paper is lower). */
  difference: Money,
});
export type MigrationTotalMismatchDetail = z.infer<typeof MigrationTotalMismatchDetail>;

/** Detail of MIGRATION_SIGNED_OFF (409). */
export const MigrationSignedOffDetail = z.object({ signoff_id: Uuid });
export type MigrationSignedOffDetail = z.infer<typeof MigrationSignedOffDetail>;

// ---------------------------------------------------------------------------------------------
// Undo a batch

export const MigrationBatchParams = z.object({ id: Uuid }).strict();
export type MigrationBatchParams = z.infer<typeof MigrationBatchParams>;

/** `POST /api/migration/batches/:id/reverse` */
export const ReverseMigrationBatchBody = z
  .object({ reason: z.string().trim().min(3).max(MIGRATION_REASON_MAX_LENGTH) })
  .strict();
export type ReverseMigrationBatchBody = z.infer<typeof ReverseMigrationBatchBody>;

/** The batch's import job and how many contracts were written off. */
export const MigrationBatchReversal = z.object({
  job: ImportJob,
  reversed_contracts: z.number().int().min(0),
});
export type MigrationBatchReversal = z.infer<typeof MigrationBatchReversal>;

/** Detail of MIGRATION_NOT_REVERSIBLE (409): the first contract that blocks, or why else. */
export const MigrationNotReversibleDetail = z.object({
  reason: z.union([MigrationBlockerReason, z.literal('not_completed')]),
  contract_id: Uuid.optional(),
  number: z.string().optional(),
});
export type MigrationNotReversibleDetail = z.infer<typeof MigrationNotReversibleDetail>;
