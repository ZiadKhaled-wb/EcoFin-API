import { describe, it, expect } from 'vitest';
import {
  ContractMigrationSource,
  MigrationBatchReversal,
  MigrationReport,
  MigrationReportQuery,
  MigrationSignOff,
  MigrationSignOffBody,
  MigrationTotalMismatchDetail,
  ReverseMigrationBatchBody,
} from './migration.js';
import { Contract } from './installments.js';

const ID = 'a0d00000-0000-4000-8000-000000000001';
const ID2 = 'a0d00000-0000-4000-8000-000000000002';

describe('M02 migration contracts', () => {
  it('the report query: ids and a format, nothing else', () => {
    expect(MigrationReportQuery.parse({}).format).toBe('json');
    expect(MigrationReportQuery.parse({ batch_id: ID, format: 'csv' }).format).toBe('csv');
    expect(MigrationReportQuery.safeParse({ format: 'pdf' }).success).toBe(false);
    expect(MigrationReportQuery.safeParse({ organization_id: ID }).success).toBe(false);
    expect(MigrationReportQuery.safeParse({ batch_id: 'nope' }).success).toBe(false);
  });

  it('the sign-off body: amounts as strings, 1-50 distinct batches, a note, nothing else', () => {
    const ok = {
      expected_open_total: '30000',
      batch_ids: [ID],
      note: 'Signed against the paper ledger',
    };
    expect(MigrationSignOffBody.safeParse(ok).success).toBe(true);
    expect(MigrationSignOffBody.safeParse({ ...ok, expected_cash_total: '25000.50' }).success).toBe(
      true,
    );
    expect(MigrationSignOffBody.safeParse({ ...ok, signed_file_id: ID2 }).success).toBe(true);
    expect(MigrationSignOffBody.safeParse({ ...ok, expected_open_total: 30000 }).success).toBe(
      false,
    );
    expect(MigrationSignOffBody.safeParse({ ...ok, expected_open_total: '-5' }).success).toBe(
      false,
    );
    expect(MigrationSignOffBody.safeParse({ ...ok, expected_open_total: '1.234' }).success).toBe(
      false,
    );
    expect(MigrationSignOffBody.safeParse({ ...ok, batch_ids: [] }).success).toBe(false);
    expect(MigrationSignOffBody.safeParse({ ...ok, batch_ids: [ID, ID] }).success).toBe(false);
    expect(MigrationSignOffBody.safeParse({ ...ok, note: 'x' }).success).toBe(false);
    expect(MigrationSignOffBody.safeParse({ ...ok, organization_id: ID }).success).toBe(false);
  });

  it('the reverse body needs a reason of 3-300 characters', () => {
    expect(ReverseMigrationBatchBody.safeParse({ reason: 'Wrong file' }).success).toBe(true);
    expect(ReverseMigrationBatchBody.safeParse({ reason: 'no' }).success).toBe(false);
    expect(ReverseMigrationBatchBody.safeParse({ reason: 'x'.repeat(301) }).success).toBe(false);
    expect(ReverseMigrationBatchBody.safeParse({ reason: 'Wrong file', force: true }).success).toBe(
      false,
    );
  });

  it('the mismatch detail keeps a negative difference', () => {
    expect(
      MigrationTotalMismatchDetail.parse({
        field: 'open_total',
        expected: '29999.00',
        system: '30000.00',
        difference: '-1.00',
      }).difference,
    ).toBe('-1.00');
  });

  it('a report and a sign-off parse', () => {
    const money = {
      original_total: '43000.00',
      paid_before: '13000.00',
      imported_total: '30000.00',
      open_now: '29000.00',
      overdue_now: '2000.00',
      collected_since: '1000.00',
    };
    const report = MigrationReport.parse({
      as_of: '2026-10-22',
      filters: {},
      totals: { contracts: 4, customers: 3, ...money },
      customers: [
        { customer_id: ID, name: 'Amal', national_id: '**********0501', contracts: 2, ...money },
      ],
      branches: [{ branch_id: ID2, name: 'Main', contracts: 4, ...money }],
      batches: [
        {
          id: ID,
          kind: 'opening_contracts',
          created_at: '2026-10-22T10:00:00.000Z',
          file_name: 'open.csv',
          contracts: 4,
          imported_total: '30000.00',
          cash_total: '0.00',
          reversed: false,
          signoff_id: null,
          can_reverse: true,
          blocker: null,
        },
      ],
      cash: [],
      cash_totals: { opening_posted: '0.00', balance_now: '0.00' },
    });
    expect(report.totals.customers).toBe(3);
    const signoff = MigrationSignOff.parse({
      id: ID,
      batch_ids: [ID],
      expected_open_total: '30000.00',
      system_open_total: '30000.00',
      expected_cash_total: null,
      system_cash_total: '0.00',
      note: 'Signed',
      signed_file_id: null,
      signed_by: { id: ID2, name: 'Owner' },
      signed_at: '2026-10-22T10:00:00.000Z',
    });
    expect(signoff.expected_cash_total).toBeNull();
  });

  it('the contract answer carries migration_source (optional, nullable)', () => {
    expect(
      ContractMigrationSource.safeParse({
        contract_ref: 'K-1',
        contract_date: '2025-01-15',
        original_total: '12000.00',
        paid_before: '3000.00',
      }).success,
    ).toBe(true);
    expect(Contract.shape.migration_source.safeParse(undefined).success).toBe(true);
    expect(Contract.shape.migration_source.safeParse(null).success).toBe(true);
    expect(MigrationBatchReversal.shape.reversed_contracts.safeParse(2).success).toBe(true);
  });
});
